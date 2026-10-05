const std = @import("std");
pub const Policy = *const fn ([]const u8, []u8) usize;

/// Copied key facts and output indices. Native retains all layouts, glyphs,
/// resource storage and hash capabilities for the lifetime of the frame.
pub const Plan = struct {
    request: []u8,
    result: []u8,
    current: usize,
    previous: usize,
    entry_count: usize = 0,
    action_count: usize = 0,
    failed: bool = false,
    pub fn init(glyph: bool, current: usize, previous: usize, capacity: usize, action_capacity: usize, frame: u64, retention: u64) Plan {
        const total = current + previous;
        const request = std.heap.page_allocator.alloc(u8, 48 + total * 80) catch @panic("text cache request allocation failed");
        const result = std.heap.page_allocator.alloc(u8, 16 + @min(capacity, total) * 4 + @min(action_capacity, total) * 12) catch @panic("text cache result allocation failed");
        @memset(request, 0);
        request[0] = 11;
        request[1] = if (glyph) 1 else 0;
        putWord(request, 4, current);
        putWord(request, 8, previous);
        putWord(request, 12, capacity);
        putWord(request, 16, action_capacity);
        putInt(request, 24, frame);
        putInt(request, 32, retention);
        return .{ .request = request, .result = result, .current = current, .previous = previous };
    }
    pub fn deinit(self: Plan) void {
        std.heap.page_allocator.free(self.request);
        std.heap.page_allocator.free(self.result);
    }
    pub fn fact(self: Plan, index: usize, key: anytype, hash: u64, last: u64) void {
        const bytes = self.request[48 + index * 80 ..][0..80];
        const T = @TypeOf(key);
        putFloat(bytes, 0, key.size);
        if (comptime @hasField(T, "glyph_id")) {
            putWord(bytes, 4, key.glyph_id);
            putInt(bytes, 8, key.font_id);
            putWord(bytes, 16, key.subpixel_x);
            putWord(bytes, 20, key.subpixel_y);
        } else {
            putFloat(bytes, 4, key.origin.x);
            putFloat(bytes, 8, key.origin.y);
            putFloat(bytes, 12, key.max_width);
            putFloat(bytes, 16, key.line_height);
            // The sixth float is a reserved zero; equality remains exact.
            putInt(bytes, 24, key.font_id);
            putInt(bytes, 32, key.fingerprint);
            putInt(bytes, 40, key.text_len);
            putInt(bytes, 48, key.glyph_count);
            putWord(bytes, 56, @intFromEnum(key.wrap));
            bytes[60] = @intCast(@intFromEnum(key.alignment));
            bytes[61] = @intCast(@intFromEnum(key.overflow));
        }
        putInt(bytes, 64, last);
        putWord(bytes, 72, @intCast(hash & 0xffffffff));
    }
    pub fn run(self: *Plan, policy: Policy) void {
        const length = policy(self.request, self.result);
        if (length < 16) @panic("truncated compiled text cache result");
        self.entry_count = word(self.result, 0);
        self.action_count = word(self.result, 4);
        const status = word(self.result, 8);
        if (status > 1 or word(self.result, 12) != 0 or self.entry_count > word(self.request, 12) or self.action_count > word(self.request, 16) or length != 16 + self.entry_count * 4 + self.action_count * 12) @panic("invalid compiled text cache result");
        self.failed = status == 1;
    }
    pub fn source(self: Plan, index: usize) usize {
        const value = word(self.result, 16 + index * 4);
        if (value >= self.current + self.previous) @panic("invalid compiled text cache entry source");
        return value;
    }
    pub const Action = struct { kind: u32, source: usize, cache: ?usize };
    pub fn action(self: Plan, index: usize) Action {
        const at = 16 + self.entry_count * 4 + index * 12;
        const kind = word(self.result, at);
        const source_index = word(self.result, at + 4);
        const cache = word(self.result, at + 8);
        if (kind > 2 or source_index >= self.current + self.previous or (cache != 0xffffffff and cache >= self.previous)) @panic("invalid compiled text cache action");
        return .{ .kind = kind, .source = source_index, .cache = if (cache == 0xffffffff) null else cache };
    }
};
fn putWord(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], std.math.cast(u32, value) orelse @panic("text cache wire integer overflow"), .little);
}
fn putInt(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
fn putFloat(bytes: []u8, at: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(value), .little);
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
