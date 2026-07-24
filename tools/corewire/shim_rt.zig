//! The shim-side runtime for a compiled core: the frame arena the
//! decoded mirror values live in, and the canonical value encoding the
//! ABI's buffers ride (snapshots, record dispatch payloads, helper
//! results, channel-entry messages).
//!
//! Staged beside the generated core_shim.zig by the build, like the
//! transpiler lane stages rt.zig beside its emitted core. The generated
//! shim's `rt` block forwards the three kernel entries the host layer
//! uses (frameAlloc/frameReset/resetAll) into this module's arena.
//!
//! The canonical value encoding, in full (one encoding for every
//! ABI-owned buffer; byte-oriented, little-endian, headerless, and
//! schema-driven — both ends derive the layout from the sidecar's type
//! table, so no field headers or tags ride the wire):
//!
//!   f64                 8 bytes, IEEE 754 double, LE. Every NaN
//!                       canonicalizes to the quiet pattern
//!                       (0x7ff8000000000000): payload bits are not
//!                       values in either source language, and engines
//!                       may rewrite them at any store, so an encoder
//!                       that preserved them could never be
//!                       deterministic across producers.
//!   i64                 8 bytes, two's complement, LE (never a bit
//!                       reinterpretation of the f64)
//!   bool                u8, 0 or 1
//!   bytes               u32 LE length + the bytes
//!   enum                u32 LE declaration-order member index
//!   optional            u8 presence (0 absent, 1 present) + the value
//!   slice               u32 LE count + the elements, in order
//!   record              fields concatenated in declaration order, no
//!                       headers; nested records inline. By-reference
//!                       fields (*const T in the mirror) encode inline
//!                       as their record value: pointer sharing is
//!                       storage, not semantics, and decode
//!                       materializes fresh values (value equality
//!                       preserved, aliasing not).
//!   union               u8 declaration-order arm index + the arm's
//!                       payload
//!
//! Buffers carry no alignment guarantee: every multi-byte read below is
//! an unaligned little-endian load.

const std = @import("std");

// ---------------------------------------------------------- the arena

var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub fn frameAllocator() std.mem.Allocator {
    return arena_state.allocator();
}

pub fn frameAlloc(comptime T: type, n: usize) []T {
    return arena_state.allocator().alloc(T, n) catch
        @panic("the core shim's frame arena is out of memory — a decoded snapshot or helper result did not fit");
}

pub fn frameCreate(comptime T: type, value: T) *T {
    const out = frameAlloc(T, 1);
    out[0] = value;
    return &out[0];
}

/// End-of-cycle reset: frees every decoded mirror, helper result, and
/// copied command buffer of the cycle. The generated shim's
/// `rt.frameReset` calls this and then the core's own frame_reset — the
/// two arenas reset together, exactly one cycle boundary.
pub fn frameReset() void {
    _ = arena_state.reset(.retain_capacity);
}

/// Full reset (the deterministic re-init seam): every arena; the
/// core's own state resets through its init entry.
pub fn resetAll() void {
    _ = arena_state.reset(.retain_capacity);
    for (&model_arenas) |*arena| _ = arena.reset(.retain_capacity);
}

// The decoded committed model lives in its own storage: it must survive
// frame resets (views read it between cycles, exactly as they read the
// transpiler lane's committed heap). TWO arenas, flipped per decode, so
// the previously returned root also survives the decode that replaces
// it — the transpiler lane gives the same one-generation grace (an old
// root stays readable until the heap's next compaction), and the bridge
// leans on it when a boot path derives twice before adopting a root.
var model_arenas = [2]std.heap.ArenaAllocator{
    std.heap.ArenaAllocator.init(std.heap.page_allocator),
    std.heap.ArenaAllocator.init(std.heap.page_allocator),
};
var model_arena_index: u1 = 0;

/// Decode a committed-model snapshot into a fresh mirror root. The
/// PREVIOUS decode's root stays valid until the decode after this one;
/// anything older is gone (the host holds exactly one committed root at
/// a time, the shipped bridge contract).
pub fn decodeSnapshot(comptime T: type, bytes: []const u8) *const T {
    model_arena_index +%= 1;
    const arena = &model_arenas[model_arena_index];
    _ = arena.reset(.retain_capacity);
    const allocator = arena.allocator();
    const out = allocator.create(T) catch @panic("the core shim's model arena is out of memory — the decoded snapshot did not fit");
    out.* = decodeExact(T, bytes, allocator);
    return out;
}

// ------------------------------------------------------------ encode

pub fn encodeAlloc(comptime T: type, value: T, allocator: std.mem.Allocator) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    encodeInto(T, value, allocator, &out) catch
        @panic("the core shim's frame arena is out of memory while encoding a dispatch payload");
    return out.items;
}

fn encodeInto(comptime T: type, value: T, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
    switch (@typeInfo(T)) {
        .bool => try out.append(allocator, @intFromBool(value)),
        .int => {
            comptime std.debug.assert(T == i64);
            try appendInt(u64, @bitCast(value), allocator, out);
        },
        .float => {
            comptime std.debug.assert(T == f64);
            const bits: u64 = if (std.math.isNan(value)) 0x7ff8000000000000 else @bitCast(value);
            try appendInt(u64, bits, allocator, out);
        },
        .@"enum" => |info| {
            // Positional: the wire value is the declaration-order
            // member INDEX, never the enum's numeric value (mirror
            // enums make them equal; the codec must not rely on it).
            const member_index: u32 = blk: {
                inline for (info.fields, 0..) |field, field_index| {
                    if (value == @field(T, field.name)) break :blk @intCast(field_index);
                }
                unreachable;
            };
            try appendInt(u32, member_index, allocator, out);
        },
        .optional => |info| {
            if (value) |inner| {
                try out.append(allocator, 1);
                try encodeInto(info.child, inner, allocator, out);
            } else {
                try out.append(allocator, 0);
            }
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child == u8) {
                    try appendInt(u32, @intCast(value.len), allocator, out);
                    try out.appendSlice(allocator, value);
                } else {
                    try appendInt(u32, @intCast(value.len), allocator, out);
                    for (value) |element| try encodeInto(info.child, element, allocator, out);
                }
            },
            .one => try encodeInto(info.child, value.*, allocator, out),
            else => @compileError("the canonical value encoding has no form for " ++ @typeName(T)),
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                try encodeInto(field.type, @field(value, field.name), allocator, out);
            }
        },
        .@"union" => |info| {
            comptime std.debug.assert(info.tag_type != null);
            switch (value) {
                inline else => |payload, tag| {
                    // Positional, like enums: the declaration-order arm
                    // index rides the wire, never the tag's numeric
                    // value.
                    const arm_index: u8 = comptime blk: {
                        for (info.fields, 0..) |field, field_index| {
                            if (std.mem.eql(u8, field.name, @tagName(tag))) break :blk @intCast(field_index);
                        }
                        unreachable;
                    };
                    try out.append(allocator, arm_index);
                    if (@TypeOf(payload) != void) {
                        try encodeInto(@TypeOf(payload), payload, allocator, out);
                    }
                },
            }
        },
        .void => {},
        else => @compileError("the canonical value encoding has no form for " ++ @typeName(T)),
    }
}

fn appendInt(comptime T: type, value: T, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
    var raw: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &raw, value, .little);
    try out.appendSlice(allocator, &raw);
}

// ------------------------------------------------------------ decode

pub const Reader = struct {
    bytes: []const u8,
    index: usize = 0,

    fn take(self: *Reader, n: usize) []const u8 {
        if (self.bytes.len - self.index < n) {
            @panic("a core buffer ended mid-value — the compiled core and the generated shim disagree about a type's layout; rebuild the app so both come from one compile");
        }
        const out = self.bytes[self.index..][0..n];
        self.index += n;
        return out;
    }

    fn int(self: *Reader, comptime T: type) T {
        return std.mem.readInt(T, self.take(@sizeOf(T))[0..@sizeOf(T)], .little);
    }
};

/// Decode one value of mirror type `T`, materializing referenced
/// records and slices into `allocator` (the shim frame arena in the
/// dispatch path).
pub fn decode(comptime T: type, reader: *Reader, allocator: std.mem.Allocator) T {
    switch (@typeInfo(T)) {
        .bool => {
            const raw = reader.take(1)[0];
            if (raw > 1) {
                @panic("a core buffer carries a boolean discriminant past 1 — the compiled core and the generated shim disagree about a type's layout; rebuild the app so both come from one compile");
            }
            return raw == 1;
        },
        .int => {
            comptime std.debug.assert(T == i64);
            return @bitCast(reader.int(u64));
        },
        .float => {
            comptime std.debug.assert(T == f64);
            return @bitCast(reader.int(u64));
        },
        .@"enum" => |info| {
            const member_index = reader.int(u32);
            if (member_index >= info.fields.len) {
                @panic("a core buffer carries an enum member index past the declared members — the compiled core and the generated shim disagree about the contract; rebuild the app");
            }
            // Positional: index into declaration order, never the
            // enum's numeric value.
            inline for (info.fields, 0..) |field, field_index| {
                if (member_index == field_index) return @field(T, field.name);
            }
            unreachable;
        },
        .optional => |info| {
            const present = reader.take(1)[0];
            if (present == 0) return null;
            if (present != 1) {
                @panic("a core buffer carries a presence discriminant past 1 — the compiled core and the generated shim disagree about a type's layout; rebuild the app so both come from one compile");
            }
            return decode(info.child, reader, allocator);
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                const count = reader.int(u32);
                if (info.child == u8) {
                    const copied = allocator.alloc(u8, count) catch @panic("the core shim's frame arena is out of memory while decoding");
                    @memcpy(copied, reader.take(count));
                    return copied;
                }
                const out = allocator.alloc(info.child, count) catch @panic("the core shim's frame arena is out of memory while decoding");
                for (out) |*element| element.* = decode(info.child, reader, allocator);
                return out;
            },
            .one => {
                const out = allocator.create(info.child) catch @panic("the core shim's frame arena is out of memory while decoding");
                out.* = decode(info.child, reader, allocator);
                return out;
            },
            else => @compileError("the canonical value encoding has no form for " ++ @typeName(T)),
        },
        .@"struct" => |info| {
            var out: T = undefined;
            inline for (info.fields) |field| {
                @field(out, field.name) = decode(field.type, reader, allocator);
            }
            return out;
        },
        .@"union" => |info| {
            comptime std.debug.assert(info.tag_type != null);
            const arm = reader.take(1)[0];
            inline for (info.fields, 0..) |field, index| {
                if (arm == index) {
                    if (field.type == void) return @unionInit(T, field.name, {});
                    return @unionInit(T, field.name, decode(field.type, reader, allocator));
                }
            }
            @panic("a core buffer carries a union arm index past the declared arms — the compiled core and the generated shim disagree about the contract; rebuild the app");
        },
        .void => return {},
        else => @compileError("the canonical value encoding has no form for " ++ @typeName(T)),
    }
}

/// Decode a whole buffer as one value; trailing bytes are the same
/// layout-skew teaching as a short read.
pub fn decodeExact(comptime T: type, bytes: []const u8, allocator: std.mem.Allocator) T {
    var reader = Reader{ .bytes = bytes };
    const out = decode(T, &reader, allocator);
    if (reader.index != bytes.len) {
        @panic("a core buffer carries bytes past the decoded value — the compiled core and the generated shim disagree about a type's layout; rebuild the app so both come from one compile");
    }
    return out;
}

// -------------------------------------------------------- boot fences

/// The boot-time pairing fence, run before the panic sink and init,
/// using only the pure identity getters: a sidecar and an object that
/// are not outputs of one compile must never reach the first dispatch.
pub fn verifyIdentity(
    core_abi_version: u32,
    core_build_id: u64,
    sidecar_abi_version: u32,
    sidecar_build_id: u64,
) void {
    if (core_abi_version != sidecar_abi_version) {
        var message: [160]u8 = undefined;
        @panic(std.fmt.bufPrint(&message, "this app's compiled core speaks ABI version {d} but its contract sidecar declares {d} — rebuild the app so both come from one compile", .{ core_abi_version, sidecar_abi_version }) catch "core/sidecar ABI version mismatch — rebuild the app");
    }
    if (core_build_id != sidecar_build_id) {
        var message: [192]u8 = undefined;
        @panic(std.fmt.bufPrint(&message, "this app's compiled core and its contract sidecar are from different builds (core {x:0>16}, sidecar {x:0>16}) — rebuild the app", .{ core_build_id, sidecar_build_id }) catch "core/sidecar build pairing mismatch — rebuild the app");
    }
}

/// The registered trap sink: route the core's teaching message into the
/// process panic path (the same capture surface the wiring installs for
/// shim/SDK code). Must not return.
pub fn panicSink(ctx: ?*anyopaque, msg: [*]const u8, msg_len: usize, address: u64) callconv(.c) void {
    _ = ctx;
    _ = address;
    @panic(msg[0..msg_len]);
}

/// The scalar dispatch entries carry numbers as f64; an integer-classed
/// value must cross exactly, and the f64 grid is only dense through
/// 2^53 - 1 — past it, distinct integers alias one wire value, so there
/// is no honest number to send. The shipped bridge refuses such values
/// before they ever reach a dispatch; the mirror holds the same line.
pub fn exactF64(value: i64) f64 {
    const bound: i64 = 9007199254740992; // 2^53: the first alias point.
    if (value >= bound or value <= -bound) {
        @panic("an integer message payload is at or past 2^53 — the f64 wire aliases such values, so dispatching one would corrupt it silently; keep integer payloads within +-(2^53 - 1)");
    }
    return @floatFromInt(value);
}

/// A bare (void) message arm carries zero payload bytes by the
/// canonical encoding; anything else is layout skew, refused like every
/// other malformed core buffer.
pub fn assertVoidPayload(payload: []const u8) void {
    if (payload.len != 0) {
        @panic("a channel message carries payload bytes on a bare arm — the compiled core and the generated shim disagree about the contract; rebuild the app so both come from one compile");
    }
}

/// The defined pre-call state for a channel entry's out-pointer pair:
/// the generated wrappers point at this byte with length zero before
/// calling, so an entry that returns without writing both slots — a
/// contract violation — yields a zero-length envelope that
/// channelEnvelope refuses with its short-buffer teaching, never a
/// slice of an undefined pointer.
pub const channel_out_guard = [1]u8{0};

/// A channel entry's split bytes envelope: whether a message was
/// produced, the produced arm's declaration-order wire tag, and the arm
/// payload bytes (canonical value encoding of the arm's mirror payload
/// type).
pub const ChannelEnvelope = struct {
    produced: bool,
    tag: u8,
    payload: []const u8,
};

/// Split a channel entry's bytes envelope — [produced u8][tag u8]
/// [payload…]. A malformed envelope is a contract violation, never a
/// silent no-message, so every framing fault refuses loudly: fewer than
/// the two header bytes, a produced byte past 1, or payload bytes
/// behind a nothing-produced header. (The tag byte is meaningless when
/// nothing was produced; a tag past the declared arms is the generated
/// unpacker's refusal — it owns the arm table.)
pub fn channelEnvelope(bytes: []const u8) ChannelEnvelope {
    if (bytes.len < 2) {
        @panic("a channel entry returned fewer than the envelope's two header bytes ([produced u8][tag u8]) — the compiled core and the generated shim disagree about the channel contract; rebuild the app so both come from one compile");
    }
    if (bytes[0] > 1) {
        @panic("a channel envelope's produced byte is past 1 — the compiled core and the generated shim disagree about the channel contract; rebuild the app so both come from one compile");
    }
    if (bytes[0] == 0 and bytes.len != 2) {
        @panic("a channel envelope carries payload bytes behind a nothing-produced header — the compiled core and the generated shim disagree about the channel contract; rebuild the app so both come from one compile");
    }
    return .{ .produced = bytes[0] == 1, .tag = bytes[1], .payload = bytes[2..] };
}

// --------------------------------------------------------------- tests

const testing = std.testing;

test "scalar encodings match the stated byte layout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Golden vectors pin the encoding itself, not just the round trip.
    try testing.expectEqualSlices(u8, &.{1}, encodeAlloc(bool, true, a));
    try testing.expectEqualSlices(u8, &.{ 0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, encodeAlloc(i64, -2, a));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0xf0, 0x3f }, encodeAlloc(f64, 1.0, a));
    try testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0, 'a', 'b', 'c' }, encodeAlloc([]const u8, "abc", a));
    const Scheme = enum(u8) { light = 0, dark = 1 };
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, encodeAlloc(Scheme, .dark, a));
    // Every NaN — negative, payload-bearing — encodes as the one quiet
    // pattern; payload bits are not values.
    const canonical_nan = [_]u8{ 0, 0, 0, 0, 0, 0, 0xf8, 0x7f };
    try testing.expectEqualSlices(u8, &canonical_nan, encodeAlloc(f64, std.math.nan(f64), a));
    try testing.expectEqualSlices(u8, &canonical_nan, encodeAlloc(f64, -std.math.nan(f64), a));
    const payload_nan: f64 = @bitCast(@as(u64, 0x7ff800000000beef));
    try testing.expectEqualSlices(u8, &canonical_nan, encodeAlloc(f64, payload_nan, a));
    try testing.expectEqualSlices(u8, &.{0}, encodeAlloc(?i64, null, a));
    try testing.expectEqualSlices(u8, &.{ 1, 5, 0, 0, 0, 0, 0, 0, 0 }, encodeAlloc(?i64, 5, a));
}

test "records, slices, references, and unions round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Role = enum(u8) { user = 0, assistant = 1 };
    const Turn = struct { id: i64, role: Role, text: []const u8 };
    const Event = union(enum) {
        insert_text: []const u8,
        clear,
        move: struct { direction: i64, extend: bool },
    };
    const Model = struct {
        turns: []const *const Turn,
        cursor: ?i64,
        last: Event,
        score: f64,
    };

    const turn_a = Turn{ .id = 1, .role = .user, .text = "hi" };
    const turn_b = Turn{ .id = 2, .role = .assistant, .text = "hello" };
    const original = Model{
        .turns = &.{ &turn_a, &turn_b },
        .cursor = 7,
        .last = .{ .move = .{ .direction = -1, .extend = true } },
        .score = 0.5,
    };

    const encoded = encodeAlloc(Model, original, a);
    const decoded = decodeExact(Model, encoded, a);

    try testing.expectEqual(@as(usize, 2), decoded.turns.len);
    // Decode materializes fresh records: value equality, not aliasing.
    try testing.expect(decoded.turns[0] != &turn_a);
    try testing.expectEqual(@as(i64, 1), decoded.turns[0].id);
    try testing.expectEqual(Role.assistant, decoded.turns[1].role);
    try testing.expectEqualStrings("hello", decoded.turns[1].text);
    try testing.expectEqual(@as(?i64, 7), decoded.cursor);
    try testing.expectEqual(@as(i64, -1), decoded.last.move.direction);
    try testing.expect(decoded.last.move.extend);
    try testing.expectEqual(@as(f64, 0.5), decoded.score);
}

test "exactF64 carries every in-range integer and matches the wire grid" {
    try testing.expectEqual(@as(f64, 9007199254740991.0), exactF64(9007199254740991));
    try testing.expectEqual(@as(f64, -9007199254740991.0), exactF64(-9007199254740991));
    try testing.expectEqual(@as(f64, 0.0), exactF64(0));
}

test "a decoded model root survives exactly one subsequent decode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Model = struct { label: []const u8, count: i64 };

    const first_bytes = encodeAlloc(Model, .{ .label = "first", .count = 1 }, a);
    const second_bytes = encodeAlloc(Model, .{ .label = "second", .count = 2 }, a);

    const first = decodeSnapshot(Model, first_bytes);
    const second = decodeSnapshot(Model, second_bytes);
    // The boot path may derive a fresh root while a consumer still
    // holds the previous one; both generations must read correctly.
    try testing.expectEqualStrings("first", first.label);
    try testing.expectEqual(@as(i64, 1), first.count);
    try testing.expectEqualStrings("second", second.label);
    try testing.expectEqual(@as(i64, 2), second.count);
    resetAll();
}

test "discriminants ride declaration-order positions, not numeric values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Sparse = enum(u8) { low = 5, high = 9 };
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, encodeAlloc(Sparse, .high, a));
    try testing.expectEqual(Sparse.high, decodeExact(Sparse, &.{ 1, 0, 0, 0 }, a));
    const Tagged = union(enum(u8)) { first: i64 = 3, second = 7 };
    try testing.expectEqualSlices(u8, &.{1}, encodeAlloc(Tagged, .second, a));
    try testing.expect(decodeExact(Tagged, &.{1}, a) == .second);
}

test "void union arms ride as the bare arm index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Event = union(enum) { insert_text: []const u8, clear };
    try testing.expectEqualSlices(u8, &.{1}, encodeAlloc(Event, .clear, a));
    const decoded = decodeExact(Event, &.{1}, a);
    try testing.expect(decoded == .clear);
    // A bare arm's canonical payload is zero bytes exactly.
    assertVoidPayload(&.{});
}

test "channel envelopes split into produced flag, tag, and payload" {
    // Nothing produced: exactly the two header bytes, tag ignored.
    const none = channelEnvelope(&.{ 0, 0 });
    try testing.expect(!none.produced);
    try testing.expectEqual(@as(usize, 0), none.payload.len);
    // A produced bare arm: header only, empty payload.
    const bare = channelEnvelope(&.{ 1, 3 });
    try testing.expect(bare.produced);
    try testing.expectEqual(@as(u8, 3), bare.tag);
    try testing.expectEqual(@as(usize, 0), bare.payload.len);
    // A produced payload arm: the tail is the arm's canonical payload
    // bytes, untouched.
    const produced = channelEnvelope(&.{ 1, 1, 2, 0, 0, 0, 0, 0, 0, 0 });
    try testing.expect(produced.produced);
    try testing.expectEqual(@as(u8, 1), produced.tag);
    try testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 0, 0, 0, 0 }, produced.payload);
}
