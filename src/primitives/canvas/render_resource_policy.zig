//! Copied resource facts and checked results. Commands, image bytes, font
//! capabilities and caller output buffers retain their native ownership.
const std = @import("std");
const canvas = @import("root.zig");
const drawing = @import("drawing.zig");
const wire = @import("glyph_atlas_policy.zig");
pub const Policy = wire.Policy;
const word = wire.word;
const put = wire.put;
const integer = wire.integer;
const float = wire.float;
const readFloat = wire.readFloat;
const allocator = std.heap.page_allocator;
const record_stride = 144;
const header_size = 32;

fn add(a: usize, b: usize) usize {
    return std.math.add(usize, a, b) catch @panic("resource wire size overflow");
}
fn mul(a: usize, b: usize) usize {
    return std.math.mul(usize, a, b) catch @panic("resource wire size overflow");
}
fn alloc(size: usize) []u8 {
    return allocator.alloc(u8, size) catch @panic("resource wire allocation failed");
}
fn rect(bytes: []u8, at: usize, value: @import("geometry").RectF) void {
    inline for (.{ "x", "y", "width", "height" }, 0..) |field, i| float(bytes, at + i * 4, @field(value, field));
}
fn readRect(bytes: []const u8, at: usize) @import("geometry").RectF {
    return .{ .x = readFloat(bytes, at), .y = readFloat(bytes, at + 4), .width = readFloat(bytes, at + 8), .height = readFloat(bytes, at + 12) };
}
fn readId(bytes: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}
fn readOptionalId(bytes: []const u8, flag: usize, at: usize) ?u64 {
    return if (word(bytes, flag) != 0) readId(bytes, at) else null;
}
fn numericRules() u8 {
    const builtin = @import("builtin");
    const shadow: u8 = if ((builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) and builtin.mode != .Debug) 16 else 0;
    return shadow | @import("render_plan_policy.zig").numericFlags();
}

const Encoder = struct {
    data: std.ArrayList(u8) = .empty,
    fn deinit(self: *Encoder) void {
        self.data.deinit(allocator);
    }
    fn append(self: *Encoder, bytes: []const u8) void {
        self.data.appendSlice(allocator, bytes) catch @panic("resource fact allocation failed");
    }
    fn zeros(self: *Encoder, length: usize) void {
        const start = self.data.items.len;
        self.data.resize(allocator, add(start, length)) catch @panic("resource fact allocation failed");
        @memset(self.data.items[start..], 0);
    }
    fn valueWord(self: *Encoder, value: usize) void {
        var bytes: [4]u8 = undefined;
        put(&bytes, 0, value);
        self.append(&bytes);
    }
    fn valueWide(self: *Encoder, value: u64) void {
        var bytes: [8]u8 = undefined;
        integer(&bytes, 0, value);
        self.append(&bytes);
    }
    fn valueFloat(self: *Encoder, value: f32) void {
        var bytes: [4]u8 = undefined;
        float(&bytes, 0, value);
        self.append(&bytes);
    }
    fn point(self: *Encoder, value: anytype) void {
        self.valueFloat(value.x);
        self.valueFloat(value.y);
    }
    fn rectangle(self: *Encoder, value: @import("geometry").RectF) void {
        inline for (.{ "x", "y", "width", "height" }) |field| self.valueFloat(@field(value, field));
    }
    fn radius(self: *Encoder, value: anytype) void {
        inline for (.{ "top_left", "top_right", "bottom_right", "bottom_left" }) |field| self.valueFloat(@field(value, field));
    }
    fn color(self: *Encoder, value: anytype) void {
        inline for (.{ "r", "g", "b", "a" }) |field| self.valueFloat(@field(value, field));
    }
    fn fill(self: *Encoder, value: drawing.Fill) void {
        self.valueWord(@intFromEnum(std.meta.activeTag(value)));
        switch (value) {
            .color => |v| self.color(v),
            .linear_gradient => |v| {
                self.point(v.start);
                self.point(v.end);
                self.valueWord(v.stops.len);
                for (v.stops) |stop| {
                    self.valueFloat(stop.offset);
                    self.color(stop.color);
                }
            },
        }
    }
    fn stroke(self: *Encoder, value: drawing.Stroke) void {
        self.valueFloat(value.width);
        self.fill(value.fill);
    }
    fn path(self: *Encoder, elements: []const drawing.PathElement) void {
        self.valueWord(elements.len);
        for (elements) |element| {
            self.valueWord(@intFromEnum(element.verb));
            for (element.points) |p| self.point(p);
        }
    }
    fn rawCommand(self: *Encoder, command: canvas.CanvasCommand) void {
        switch (command) {
            .pop_clip, .push_opacity, .pop_opacity, .transform => {},
            .push_clip => |v| {
                self.rectangle(v.rect);
                self.radius(v.radius);
            },
            .fill_rect => |v| {
                self.rectangle(v.rect);
                self.fill(v.fill);
            },
            .stroke_rect => |v| {
                self.rectangle(v.rect);
                self.radius(v.radius);
                self.stroke(v.stroke);
            },
            .fill_rounded_rect => |v| {
                self.rectangle(v.rect);
                self.radius(v.radius);
                self.fill(v.fill);
            },
            .draw_line => |v| {
                self.point(v.from);
                self.point(v.to);
                self.stroke(v.stroke);
            },
            .fill_path => |v| {
                self.path(v.elements);
                self.fill(v.fill);
            },
            .stroke_path => |v| {
                self.path(v.elements);
                self.stroke(v.stroke);
                self.valueWord(@intFromEnum(v.cap));
            },
            .draw_image => |v| {
                self.valueWide(v.image_id);
                self.valueWord(@intFromBool(v.src != null));
                self.rectangle(v.src orelse .{});
                self.valueWord(@intFromEnum(v.fit));
                self.valueWord(@intFromEnum(v.sampling));
                self.rectangle(v.dst);
                self.valueFloat(v.opacity);
                self.radius(v.radius);
            },
            .draw_text => |v| {
                self.valueWide(v.font_id);
                self.valueFloat(v.size);
                self.point(v.origin);
                self.valueWord(v.text.len);
                self.append(v.text);
                self.valueWord(v.glyphs.len);
                for (v.glyphs) |g| {
                    self.valueWord(g.id);
                    self.valueWide(g.font_id);
                    self.valueFloat(g.x);
                    self.valueFloat(g.y);
                    self.valueFloat(g.advance);
                    self.valueWord(g.text_start);
                    self.valueWord(g.text_len);
                }
                self.valueWord(@intFromBool(v.text_layout != null));
                if (v.text_layout) |options| {
                    self.valueFloat(options.max_width);
                    self.valueFloat(options.line_height);
                    self.valueWord(@intFromEnum(options.wrap));
                    self.valueWord(@intFromEnum(options.alignment));
                    self.valueWord(@intFromEnum(options.overflow));
                }
                self.color(v.color);
            },
            .shadow => |v| {
                self.rectangle(v.rect);
                self.radius(v.radius);
                self.valueFloat(v.offset.dx);
                self.valueFloat(v.offset.dy);
                self.valueFloat(v.blur);
                self.valueFloat(v.spread);
                self.color(v.color);
            },
            .blur => |v| {
                self.rectangle(v.rect);
                self.valueFloat(v.radius);
            },
        }
    }
};

fn facts(comptime mode: u8, plan: anytype, capacity: usize) Encoder {
    var e = Encoder{};
    e.zeros(add(header_size, mul(plan.commands.len, record_stride)));
    for (plan.commands, 0..) |item, i| {
        const command = if (mode == 1) item.command else item;
        const at = header_size + i * record_stride;
        const start = e.data.items.len;
        e.rawCommand(command);
        const bytes = e.data.items;
        put(bytes, at, i);
        put(bytes, at + 4, @intFromEnum(std.meta.activeTag(command)));
        integer(bytes, at + 8, command.objectId() orelse 0);
        if (mode == 1) {
            put(bytes, at + 16, @intFromBool(item.id != null));
            integer(bytes, at + 24, item.id orelse 0);
            rect(bytes, at + 32, item.local_bounds);
            rect(bytes, at + 48, item.bounds);
            float(bytes, at + 64, item.opacity);
            put(bytes, at + 68, @intFromBool(item.clip != null));
            rect(bytes, at + 72, item.clip orelse .{});
            inline for (.{ "a", "b", "c", "d", "tx", "ty" }, 0..) |field, axis| float(bytes, at + 88 + axis * 4, @field(item.transform, field));
        } else if (command == .draw_text) put(bytes, at + 120, 2);
        put(bytes, at + 112, start);
        put(bytes, at + 116, bytes.len - start);
    }
    e.data.items[0..4].* = .{ 64, 1, mode, numericRules() };
    put(e.data.items, 4, plan.commands.len);
    put(e.data.items, 8, capacity);
    put(e.data.items, 16, e.data.items.len);
    return e;
}

// Envelope/source proofs never duplicate portable admission, grouping or hashes.
pub fn resultValid(request: []const u8, result: []const u8, capacity: usize) bool {
    if (request.len < 32 or result.len < 32 or request[2] > 2) return false;
    const mode = request[2];
    const stride: usize = switch (mode) {
        0 => 80,
        1 => 104,
        else => 80,
    };
    const count: usize = word(result, 0);
    const total: usize = word(request, 4);
    const status = word(result, 4);
    const facts_stride: usize = if (mode == 0) 48 else record_stride;
    if (total > (request.len - 32) / facts_stride) return false;
    if (mode == 0 and word(request, 12) > (request.len - 32 - total * facts_stride) / 48) return false;
    if (count > capacity or count > total or count > (result.len - 32) / stride or result.len != 32 + count * stride or status > 2 or word(result, 28) != 0 or (status == 1 and count != capacity) or (mode == 1 and status == 2)) return false;
    if (status != 2) for (2..7) |i| {
        if (word(result, i * 4) != 0) return false;
    };
    var previous: ?usize = null;
    for (0..count) |i| {
        const at = 32 + i * stride;
        if (mode == 0) {
            const source = word(result, at + 8);
            var origin: ?usize = null;
            for (0..total) |j| {
                const index = 32 + j * 48;
                if (index + 48 > request.len) return false;
                if (word(request, index) == source) {
                    origin = index;
                    break;
                }
            }
            const raw = origin orelse return false;
            if (previous != null and source <= previous.? or readId(result, at) != readId(request, raw + 16) or word(result, at + 12) > 1 or word(result, at + 24) == 0 or word(result, at + 24) > total or word(result, at + 28) != 0 or word(result, at + 76) != 0) return false;
            if (word(result, at + 12) == 0 and readId(result, at + 16) != 0) return false;
            const resource: usize = word(result, at + 48);
            const refs = 32 + total * 48;
            if (resource == 0xffffffff) {
                if (readId(result, at + 32) != 0 or readId(result, at + 40) != 0) return false;
            } else if (resource >= word(request, 12) or refs + resource * 48 + 48 > request.len or readId(result, at) != readId(request, refs + resource * 48) or !std.mem.eql(u8, result[at + 32 ..][0..16], request[refs + resource * 48 + 8 ..][0..16])) return false;
            previous = source;
        } else {
            const source: usize = word(result, at + (if (mode == 1) @as(usize, 0) else 4));
            if (source >= total or previous != null and source <= previous.?) return false;
            const raw = 32 + source * record_stride;
            if (raw + record_stride > request.len or word(result, at + 8) > 1 or word(result, at + 12) > (if (mode == 1) @as(u32, 0) else 1) or word(result, at + 8) == 0 and readId(result, at + 16) != 0) return false;
            if (mode == 1) {
                const length: usize = word(result, at + 4);
                if (length == 0 or length > total - source or word(result, at + 96) != 0 or word(result, at + 100) != 0 or !std.mem.eql(u8, result[at + 40 ..][0..48], request[raw + 64 ..][0..48])) return false;
                if (word(result, at + 8) != 0 and readOptionalId(result, at + 8, at + 16) != readOptionalId(request, raw + 16, raw + 24)) return false;
                if (previous != null and source < previous.?) return false;
                previous = source + length - 1;
            } else {
                if (word(result, at) > 4 or word(result, at + 68) != 0 or readOptionalId(result, at + 8, at + 16) != @as(?u64, if (readId(request, raw + 8) == 0) null else readId(request, raw + 8))) return false;
                previous = source;
            }
        }
    }
    if (status == 2) {
        const source: usize = word(result, 8);
        if (source >= total) return false;
        if (mode == 2) {
            const raw = 32 + source * record_stride;
            if (raw + record_stride > request.len or word(request, raw + 4) != 12 or word(request, raw + 120) != 2 or (previous != null and source <= previous.?)) return false;
            for (3..7) |i| if (word(result, i * 4) != 0) return false;
        } else {
            const resource: usize = word(result, 12);
            const offset: usize = word(result, 16);
            const refs = 32 + total * 48;
            if (resource >= word(request, 12) or refs + resource * 48 + 48 > request.len or readId(request, 32 + source * 48 + 16) != readId(request, refs + resource * 48) or offset >= word(request, refs + resource * 48 + 32)) return false;
        }
    }
    return true;
}

fn applyResources(planner: anytype, bytes: []const u8) void {
    planner.len = word(bytes, 0);
    for (planner.resources[0..planner.len], 0..) |*item, i| {
        const at = 32 + i * 80;
        item.* = .{ .kind = @enumFromInt(word(bytes, at)), .command_index = word(bytes, at + 4), .id = readOptionalId(bytes, at + 8, at + 16), .bounds = if (word(bytes, at + 12) != 0) readRect(bytes, at + 24) else null, .image_id = readId(bytes, at + 40), .font_id = readId(bytes, at + 48), .gradient_stop_count = word(bytes, at + 56), .glyph_count = word(bytes, at + 60), .text_len = word(bytes, at + 64), .fingerprint = readId(bytes, at + 72) };
    }
}
pub fn resources(planner: anytype, list: anytype, policy: Policy) canvas.Error!@import("render_generic_resources.zig").RenderResourcePlan {
    planner.reset();
    var e = facts(2, list, planner.resources.len);
    defer e.deinit();
    const end = e.data.items.len;
    const output = alloc(add(32, mul(@min(list.commands.len, planner.resources.len), 80)));
    defer allocator.free(output);
    var previous: ?usize = null;
    while (true) {
        const length = policy(e.data.items, output);
        if (length > output.len or !resultValid(e.data.items, output[0..length], planner.resources.len)) @panic("invalid compiled resource plan");
        const result = output[0..length];
        applyResources(planner, result);
        const status = word(result, 4);
        if (status == 1) return error.RenderResourceListFull;
        if (status == 0) return .{ .resources = planner.resources[0..planner.len] };
        const source: usize = word(result, 8);
        if (previous != null and source <= previous.?) @panic("resource capability did not advance");
        // Publish the accepted prefix before the observable text capability.
        const bounds = list.commands[source].bounds();
        const at = 32 + source * record_stride;
        put(e.data.items, at + 120, @intFromBool(bounds != null));
        rect(e.data.items, at + 124, bounds orelse .{});
        e.data.shrinkRetainingCapacity(end);
        put(e.data.items, 20, source);
        put(e.data.items, 24, length);
        e.append(result);
        previous = source;
    }
}
pub fn layers(planner: anytype, plan: anytype, policy: Policy) canvas.Error!@import("render_layers.zig").RenderLayerPlan {
    planner.reset();
    var e = facts(1, plan, planner.layers.len);
    defer e.deinit();
    const output = alloc(add(32, mul(@min(plan.commands.len, planner.layers.len), 104)));
    defer allocator.free(output);
    const length = policy(e.data.items, output);
    if (length > output.len or !resultValid(e.data.items, output[0..length], planner.layers.len)) @panic("invalid compiled layer plan");
    const result = output[0..length];
    planner.len = word(result, 0);
    for (planner.layers[0..planner.len], 0..) |*item, i| {
        const at = 32 + i * 104;
        item.* = .{ .command_start = word(result, at), .command_count = word(result, at + 4), .id = readOptionalId(result, at + 8, at + 16), .bounds = readRect(result, at + 24), .opacity = readFloat(result, at + 40), .clip = if (word(result, at + 44) != 0) readRect(result, at + 48) else null, .fingerprint = readId(result, at + 88) };
        inline for (.{ "a", "b", "c", "d", "tx", "ty" }, 0..) |field, axis| @field(item.transform, field) = readFloat(result, at + 64 + axis * 4);
    }
    if (word(result, 4) != 0) return error.LayerListFull;
    return .{ .layers = planner.layers[0..planner.len] };
}
pub fn images(planner: anytype, plan: anytype, policy: Policy) canvas.Error!@import("render_images.zig").RenderImagePlan {
    planner.reset();
    var e = Encoder{};
    defer e.deinit();
    var count: usize = 0;
    for (plan.commands) |command| {
        if (command.command == .draw_image) count += 1;
    }
    const refs = add(32, mul(count, 48));
    e.zeros(add(refs, mul(planner.image_resources.len, 48)));
    e.data.items[0..4].* = .{ 64, 1, 0, numericRules() };
    put(e.data.items, 4, count);
    put(e.data.items, 8, planner.images.len);
    put(e.data.items, 12, planner.image_resources.len);
    put(e.data.items, 16, e.data.items.len);
    var next: usize = 0;
    for (plan.commands, 0..) |command, index| {
        if (command.command != .draw_image) continue;
        const at = 32 + next * 48;
        next += 1;
        put(e.data.items, at, index);
        put(e.data.items, at + 4, @intFromBool(command.id != null));
        integer(e.data.items, at + 8, command.id orelse 0);
        integer(e.data.items, at + 16, command.command.draw_image.image_id);
        rect(e.data.items, at + 24, command.bounds);
    }
    for (planner.image_resources, 0..) |image, i| {
        const at = refs + i * 48;
        integer(e.data.items, at, image.id);
        integer(e.data.items, at + 8, image.width);
        integer(e.data.items, at + 16, image.height);
        integer(e.data.items, at + 24, image.content_fingerprint);
        put(e.data.items, at + 32, image.pixels.len);
    }
    const end = e.data.items.len;
    const output = alloc(add(32, mul(@min(count, planner.images.len), 80)));
    defer allocator.free(output);
    var previous_source: ?usize = null;
    var previous_offset: usize = 0;
    while (true) {
        const length = policy(e.data.items, output);
        if (length > output.len or !resultValid(e.data.items, output[0..length], planner.images.len)) @panic("invalid compiled image plan");
        const result = output[0..length];
        planner.len = word(result, 0);
        for (planner.images[0..planner.len], 0..) |*item, i| {
            const at = 32 + i * 80;
            const resource = word(result, at + 48);
            item.* = .{ .image_id = readId(result, at), .command_index = word(result, at + 8), .id = readOptionalId(result, at + 12, at + 16), .draw_count = word(result, at + 24), .width = @intCast(readId(result, at + 32)), .height = @intCast(readId(result, at + 40)), .pixels = if (resource == 0xffffffff) &.{} else planner.image_resources[resource].pixels, .bounds = readRect(result, at + 52), .fingerprint = readId(result, at + 68) };
        }
        const status = word(result, 4);
        if (status == 1) return error.ImageListFull;
        if (status == 0) return .{ .images = planner.images[0..planner.len] };
        const source: usize = word(result, 8);
        const resource: usize = word(result, 12);
        const offset: usize = word(result, 16);
        if (previous_source != null and (source < previous_source.? or source == previous_source.? and offset <= previous_offset)) @panic("image storage read did not advance");
        const pixels = planner.image_resources[resource].pixels;
        const chunk = @min(pixels.len - offset, 65536);
        e.data.shrinkRetainingCapacity(end);
        put(e.data.items, 20, source);
        put(e.data.items, 24, length);
        put(e.data.items, 28, chunk);
        e.append(result);
        e.append(pixels[offset..][0..chunk]);
        previous_source = source;
        previous_offset = offset;
    }
}

test "render resource copied transport bounds source indices prefixes and borrowed resource slots" {
    var request: [224]u8 = @splat(0);
    var output: [136]u8 = @splat(0);
    request[2] = 1;
    put(&request, 4, 1);
    put(&output, 0, 1);
    put(&output, 36, 1);
    try std.testing.expect(resultValid(&request, &output, 1));
    for ([_]usize{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 128, 132 }) |at| {
        const before = word(&output, at);
        put(&output, at, 0xffffffff);
        try std.testing.expect(!resultValid(&request, &output, 1));
        put(&output, at, before);
    }
    for (0..output.len) |length| try std.testing.expect(!resultValid(&request, output[0..length], 1));
    put(&request, 4, 0xffffffff);
    try std.testing.expect(!resultValid(&request, &output, 1));
    @memset(&request, 0);
    @memset(&output, 0);
    request[2] = 0;
    put(&request, 4, 1);
    put(&request, 12, 1);
    integer(&request, 48, 7);
    integer(&request, 80, 7);
    integer(&request, 88, 0xffffffffffffffff);
    integer(&request, 96, 0xf123456789abcdef);
    put(&output, 0, 1);
    integer(&output, 32, 7);
    put(&output, 56, 1);
    integer(&output, 64, 0xffffffffffffffff);
    integer(&output, 72, 0xf123456789abcdef);
    try std.testing.expect(resultValid(&request, output[0..112], 1));
    for ([_]usize{ 0, 4, 8, 28, 32, 40, 44, 48, 56, 60, 64, 72, 80, 108 }) |at| {
        const before = word(&output, at);
        put(&output, at, 0xffffffff);
        if (word(&output, at) != before) try std.testing.expect(!resultValid(&request, output[0..112], 1));
        put(&output, at, before);
    }
    put(&output, 4, 2);
    put(&output, 12, 1);
    try std.testing.expect(!resultValid(&request, output[0..112], 1));
    put(&output, 12, 0);
    put(&request, 112, 10);
    put(&output, 16, 10);
    try std.testing.expect(!resultValid(&request, output[0..112], 1));
}
