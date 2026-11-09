//! Native-owned typed storage and borrowed-span transport for session codecs.
const std = @import("std");
const journal = @import("session_journal.zig");
const reference = @import("session_codec_reference.zig");
const platform = @import("../platform/root.zig");
pub const Policy = ?*const fn ([]const u8, []u8) usize;

const Slots = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    count: u32 = 0,
    fn deinit(self: *Slots) void {
        self.bytes.deinit(self.allocator);
    }
    fn add(self: *Slots, path: []const u8, bytes: []const u8) !void {
        var prefix: [8]u8 = undefined;
        std.mem.writeInt(u32, prefix[0..4], @intCast(path.len), .little);
        std.mem.writeInt(u32, prefix[4..8], @intCast(bytes.len), .little);
        try self.bytes.appendSlice(self.allocator, &prefix);
        try self.bytes.appendSlice(self.allocator, path);
        try self.bytes.appendSlice(self.allocator, bytes);
        self.count += 1;
    }
    fn scalar(self: *Slots, path: []const u8, comptime T: type, scalar_value: T) !void {
        const width = @divExact(@typeInfo(T).int.bits, 8);
        var bytes: [width]u8 = undefined;
        std.mem.writeInt(T, &bytes, scalar_value, .little);
        try self.add(path, &bytes);
    }
    fn value(self: *Slots, path: []const u8, value_: anytype) !void {
        const T = @TypeOf(value_);
        switch (@typeInfo(T)) {
            .void => {},
            .bool => try self.add(path, &.{@intFromBool(value_)}),
            .int => try self.scalar(path, T, value_),
            .float => try self.scalar(path, u32, @as(u32, @bitCast(value_))),
            .@"enum" => if (T == platform.WidgetAccessibilityActionKind) try self.scalar(path, i32, @intFromEnum(value_)) else try self.add(path, &.{@intCast(@intFromEnum(value_))}),
            .optional => {
                try self.add(path, &.{@intFromBool(value_ != null)});
                if (value_) |v| {
                    if (@typeInfo(@TypeOf(v)) == .int) {
                        var path_buffer: [256]u8 = undefined;
                        const nested = try std.fmt.bufPrint(&path_buffer, "{s}.value", .{path});
                        try self.value(nested, v);
                    } else try self.value(path, v);
                }
            },
            .array => |a| {
                if (a.child != u8) @compileError("unsupported journal native array");
                try self.add(path, &value_);
            },
            .pointer => |p| {
                if (p.size != .slice) return;
                if (p.child == u8) try self.add(path, value_) else if (p.child == []const u8) {
                    try self.scalar(path, u64, value_.len);
                    // The codec rejects path-count excess; expose bounded storage only.
                    for (value_[0..@min(value_.len, journal.max_session_drop_paths)], 0..) |v, i| {
                        var path_buffer: [256]u8 = undefined;
                        const nested = try std.fmt.bufPrint(&path_buffer, "{s}/{d}", .{ path, i });
                        try self.add(nested, v);
                    }
                } else @compileError("unsupported native journal slice");
            },
            .@"struct" => |st| inline for (st.fields) |field| {
                var path_buffer: [256]u8 = undefined;
                const nested = if (path.len == 0) field.name else try std.fmt.bufPrint(&path_buffer, "{s}.{s}", .{ path, field.name });
                try self.value(nested, @field(value_, field.name));
            },
            else => @compileError("unsupported native journal storage"),
        }
    }
};
const Span = struct { path: []const u8, bytes: []const u8 };
const Program = struct {
    allocator: std.mem.Allocator,
    allocation: []u8,
    size: usize,
    input: []const u8,
    fn deinit(self: Program) void {
        self.allocator.free(self.allocation);
    }
    fn word(self: Program, at: usize) u32 {
        return std.mem.readInt(u32, self.allocation[at..][0..4], .little);
    }
    fn status(self: Program) journal.JournalError!void {
        switch (self.word(4)) {
            0 => {},
            1 => return error.JournalCorrupt,
            2 => return error.JournalRecordOverBudget,
            else => @panic("invalid journal codec status"),
        }
    }
    fn name(self: Program) []const u8 {
        return self.allocation[16..][0..self.word(12)];
    }
    fn span(self: Program, path: []const u8) ?[]const u8 {
        var at: usize = 16 + self.word(12);
        for (0..self.word(8)) |_| {
            const length: usize = self.word(at);
            at += 4;
            const key = self.allocation[at..][0..length];
            at += length;
            const first: usize = self.word(at);
            const size: usize = self.word(at + 4);
            at += 8;
            if (std.mem.eql(u8, path, key)) return self.input[first..][0..size];
        }
        return null;
    }
    fn validate(self: Program, decoding: bool) void {
        if (self.size < 16 or self.size > self.allocation.len or self.word(0) != 1 or self.word(4) > 2 or self.word(12) > self.size - 16) @panic("invalid journal codec header");
        if (!decoding) {
            if (self.word(12) != 0 or self.word(8) != self.size - 16 or self.word(4) == 1) @panic("invalid journal encoded extent");
            return;
        }
        if (self.word(8) > 512 or self.word(4) == 2) @panic("invalid journal decoded count");
        var at: usize = 16 + self.word(12);
        for (0..self.word(8)) |_| {
            if (self.size - at < 4) @panic("short journal span name");
            const length: usize = self.word(at);
            at += 4;
            if (length > 256 or length > self.size - at or self.size - at - length < 8) @panic("invalid journal span name");
            at += length;
            const first: usize = self.word(at);
            const size: usize = self.word(at + 4);
            at += 8;
            if (first > self.input.len or size > self.input.len - first) @panic("invalid borrowed journal span");
        }
        if (at != self.size) @panic("trailing journal span program");
    }
};
fn invoke(allocator: std.mem.Allocator, policy: *const fn ([]const u8, []u8) usize, record: u8, name: []const u8, slots: Slots, input: []const u8, capacity: usize, decoding: bool) !Program {
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(allocator);
    var header: [24]u8 = @splat(0);
    header[0..4].* = .{ 30, 1, @intFromBool(decoding), record };
    std.mem.writeInt(u32, header[4..8], @intCast(capacity), .little);
    std.mem.writeInt(u32, header[8..12], @bitSizeOf(usize), .little);
    std.mem.writeInt(u32, header[12..16], @intCast(name.len), .little);
    std.mem.writeInt(u32, header[16..20], slots.count, .little);
    std.mem.writeInt(u32, header[20..24], @intCast(input.len), .little);
    try request.appendSlice(allocator, &header);
    try request.appendSlice(allocator, name);
    try request.appendSlice(allocator, slots.bytes.items);
    try request.appendSlice(allocator, input);
    const output = try allocator.alloc(u8, if (decoding) 64 * 1024 else 16 + @min(capacity, request.items.len));
    errdefer allocator.free(output);
    const size = policy(request.items, output);
    const result = Program{ .allocator = allocator, .allocation = output, .size = size, .input = input };
    result.validate(decoding);
    return result;
}
fn encode(policy: *const fn ([]const u8, []u8) usize, record: u8, value: anytype, buffer: []u8) journal.JournalError![]const u8 {
    var scratch = std.heap.stackFallback(16 * 1024, std.heap.page_allocator);
    const allocator = scratch.get();
    var slots: Slots = .{ .allocator = allocator };
    defer slots.deinit();
    const T = @TypeOf(value);
    var name: []const u8 = "";
    if (T == platform.Event) {
        switch (value) {
            inline else => |v, tag| {
                name = @tagName(tag);
                slots.value("", v) catch return error.JournalRecordOverBudget;
            },
        }
    } else slots.value("", value) catch return error.JournalRecordOverBudget;
    const program = invoke(allocator, policy, record, name, slots, "", buffer.len, false) catch return error.JournalRecordOverBudget;
    defer program.deinit();
    const size: usize = program.word(8);
    if (size > buffer.len) @panic("invalid encoded journal capacity");
    @memcpy(buffer[0..size], program.allocation[16..][0..size]);
    try program.status();
    return buffer[0..size];
}
fn initial(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .@"struct" => |st| blk: {
            var result: T = undefined;
            inline for (st.fields) |field| @field(result, field.name) = if (field.default_value_ptr) |ptr| @as(*const field.type, @ptrCast(@alignCast(ptr))).* else initial(field.type);
            break :blk result;
        },
        .@"enum" => std.meta.tags(T)[0],
        .pointer => |p| if (p.size == .slice) &.{} else @compileError("missing native pointer default"),
        else => std.mem.zeroes(T),
    };
}
fn hydrate(program: Program, path: []const u8, comptime T: type, storage: *journal.EventDecodeStorage) T {
    switch (@typeInfo(T)) {
        .void => return {},
        .@"struct" => |st| {
            var result = initial(T);
            inline for (st.fields) |field| {
                var buffer: [256]u8 = undefined;
                const nested = if (path.len == 0) field.name else std.fmt.bufPrint(&buffer, "{s}.{s}", .{ path, field.name }) catch unreachable;
                if (T == platform.ShortcutModifiers) {
                    const byte = (program.span(path) orelse return result)[0];
                    inline for (st.fields, 0..) |f, i| @field(result, f.name) = byte & (@as(u8, 1) << @intCast(i)) != 0;
                    return result;
                }
                if (hasSpan(program, nested)) @field(result, field.name) = hydrate(program, nested, field.type, storage);
            }
            return result;
        },
        .optional => |o| {
            if (@typeInfo(o.child) == .pointer and @typeInfo(o.child).pointer.size != .slice) return null;
            const bytes = program.span(path) orelse return null;
            if (bytes.len != 1 or bytes[0] > 1) @panic("invalid journal optional span");
            if (bytes[0] == 0) return null;
            if (@typeInfo(o.child) == .int) {
                var buffer: [256]u8 = undefined;
                return hydrate(program, std.fmt.bufPrint(&buffer, "{s}.value", .{path}) catch unreachable, o.child, storage);
            }
            return hydrate(program, path, o.child, storage);
        },
        .pointer => |p| {
            if (p.size != .slice) return initial(T);
            if (p.child == u8) return program.span(path) orelse initial(T);
            if (p.child == []const u8) {
                const bytes = program.span(path) orelse @panic("missing drop path count");
                const count = std.mem.readInt(u16, bytes[0..2], .little);
                if (count > storage.drop_paths.len) @panic("invalid journal drop path count");
                return storage.drop_paths[0..count];
            }
            @compileError("unsupported decoded native journal slice");
        },
        .array => |a| {
            const bytes = program.span(path) orelse return initial(T);
            if (a.child != u8 or bytes.len != a.len) @panic("invalid journal byte array");
            return bytes[0..a.len].*;
        },
        else => {
            const bytes = program.span(path) orelse return initial(T);
            switch (@typeInfo(T)) {
                .bool => {
                    if (bytes.len != 1 or bytes[0] > 1) @panic("invalid journal bool span");
                    return bytes[0] == 1;
                },
                .int => {
                    if (T == usize) {
                        if (bytes.len == 4) return std.mem.readInt(u32, bytes[0..4], .little);
                        if (bytes.len != 8) @panic("invalid journal usize span");
                        return std.math.cast(usize, std.mem.readInt(u64, bytes[0..8], .little)) orelse @panic("invalid journal usize width");
                    }
                    const width = @divExact(@typeInfo(T).int.bits, 8);
                    if (bytes.len != width) @panic("invalid journal integer span");
                    return std.mem.readInt(T, bytes[0..width], .little);
                },
                .float => {
                    if (bytes.len != 4) @panic("invalid journal float span");
                    return @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
                },
                .@"enum" => {
                    const value = if (T == platform.WidgetAccessibilityActionKind) std.mem.readInt(i32, bytes[0..4], .little) else @as(i32, bytes[0]);
                    return std.enums.fromInt(T, value) orelse @panic("invalid journal enum span");
                },
                else => @compileError("unsupported decoded journal storage"),
            }
        },
    }
}
fn hasSpan(program: Program, path: []const u8) bool {
    if (program.span(path) != null) return true;
    var at: usize = 16 + program.word(12);
    for (0..program.word(8)) |_| {
        const length: usize = program.word(at);
        at += 4;
        const key = program.allocation[at..][0..length];
        at += length + 8;
        if (key.len > path.len and std.mem.startsWith(u8, key, path) and key[path.len] == '.') return true;
    }
    return false;
}
fn decode(policy: *const fn ([]const u8, []u8) usize, record: u8, input: []const u8, comptime T: type, storage: *journal.EventDecodeStorage) journal.JournalError!T {
    var scratch = std.heap.stackFallback(80 * 1024, std.heap.page_allocator);
    const allocator = scratch.get();
    const program = invoke(allocator, policy, record, "", .{ .allocator = allocator }, input, 0, true) catch return error.JournalCorrupt;
    defer program.deinit();
    // Preserve the original decoder's partial path-list writes on corruption.
    for (0..storage.drop_paths.len) |i| {
        var buffer: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "paths/{d}", .{i}) catch unreachable;
        if (program.span(path)) |bytes| storage.drop_paths[i] = bytes else break;
    }
    try program.status();
    if (T == platform.Event) {
        const tag = std.meta.stringToEnum(std.meta.Tag(T), program.name()) orelse @panic("invalid decoded event storage name");
        switch (tag) {
            inline else => |t| return @unionInit(T, @tagName(t), hydrate(program, "", @FieldType(T, @tagName(t)), storage)),
        }
    } else return hydrate(program, "", T, storage);
}

pub fn encodeEvent(policy: Policy, value: platform.Event, buffer: []u8) journal.JournalError![]const u8 {
    const callback = policy orelse return reference.encodeEvent(value, buffer);
    return encode(callback, 2, value, buffer);
}
pub fn decodeEvent(policy: Policy, bytes: []const u8, storage: *journal.EventDecodeStorage) journal.JournalError!platform.Event {
    const callback = policy orelse return reference.decodeEvent(bytes, storage);
    return decode(callback, 2, bytes, platform.Event, storage);
}

pub fn encodeEffect(policy: Policy, value: journal.EffectResultRecord, buffer: []u8) journal.JournalError![]const u8 {
    const callback = policy orelse return reference.encodeEffect(value, buffer);
    return encode(callback, 3, value, buffer);
}
pub fn decodeEffect(policy: Policy, bytes: []const u8) journal.JournalError!journal.EffectResultRecord {
    const callback = policy orelse return reference.decodeEffect(bytes);
    var storage: journal.EventDecodeStorage = .{};
    return decode(callback, 3, bytes, journal.EffectResultRecord, &storage);
}

pub fn encodeHeader(policy: Policy, value: journal.Header, buffer: []u8) journal.JournalError![]const u8 {
    const callback = policy orelse return reference.encodeHeader(value, buffer);
    return encode(callback, 1, value, buffer);
}
pub fn decodeHeader(policy: Policy, bytes: []const u8) journal.JournalError!journal.Header {
    const callback = policy orelse return reference.decodeHeader(bytes);
    var storage: journal.EventDecodeStorage = .{};
    return decode(callback, 1, bytes, journal.Header, &storage);
}

pub fn encodeCheckpoint(policy: Policy, value: journal.Checkpoint, buffer: []u8) journal.JournalError![]const u8 {
    const callback = policy orelse return reference.encodeCheckpoint(value, buffer);
    return encode(callback, 4, value, buffer);
}
pub fn decodeCheckpoint(policy: Policy, bytes: []const u8) journal.JournalError!journal.Checkpoint {
    const callback = policy orelse return reference.decodeCheckpoint(bytes);
    var storage: journal.EventDecodeStorage = .{};
    return decode(callback, 4, bytes, journal.Checkpoint, &storage);
}

pub fn encodeScreenshot(policy: Policy, value: journal.ScreenshotMark, buffer: []u8) journal.JournalError![]const u8 {
    const callback = policy orelse return reference.encodeScreenshot(value, buffer);
    return encode(callback, 5, value, buffer);
}
pub fn decodeScreenshot(policy: Policy, bytes: []const u8) journal.JournalError!journal.ScreenshotMark {
    const callback = policy orelse return reference.decodeScreenshot(bytes);
    var storage: journal.EventDecodeStorage = .{};
    return decode(callback, 5, bytes, journal.ScreenshotMark, &storage);
}

pub fn encodeWindowChrome(policy: Policy, value: journal.WindowChromeRecord, buffer: []u8) journal.JournalError![]const u8 {
    const callback = policy orelse return reference.encodeWindowChrome(value, buffer);
    return encode(callback, 7, value, buffer);
}
pub fn decodeWindowChrome(policy: Policy, bytes: []const u8) journal.JournalError!journal.WindowChromeRecord {
    const callback = policy orelse return reference.decodeWindowChrome(bytes);
    var storage: journal.EventDecodeStorage = .{};
    return decode(callback, 7, bytes, journal.WindowChromeRecord, &storage);
}

pub fn encodeEnd(policy: Policy, value: journal.End, buffer: []u8) journal.JournalError![]const u8 {
    const callback = policy orelse return reference.encodeEnd(value, buffer);
    return encode(callback, 6, value, buffer);
}
pub fn decodeEnd(policy: Policy, bytes: []const u8) journal.JournalError!journal.End {
    const callback = policy orelse return reference.decodeEnd(bytes);
    var storage: journal.EventDecodeStorage = .{};
    return decode(callback, 6, bytes, journal.End, &storage);
}
