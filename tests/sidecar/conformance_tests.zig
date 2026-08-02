//! Sidecar-shim conformance: for every core in the ts-core corpus, the
//! build runs BOTH lanes — today's transpiler emitting core.zig, and
//! corewire generating the mirror from that core's contract sidecar —
//! and this suite holds their reflection surfaces byte-identical:
//!
//! 1. `layout_fingerprint.describe` of Model and Msg (field names,
//!    order, types, enum values, union tags — everything the journal
//!    and wire identities hash) must match exactly.
//! 2. The model-contract artifact (the serialized Contract `native
//!    check` verifies markup against: scalars, nested groups,
//!    iterables, msg payload classes, unbound lists) must match
//!    byte-for-byte, after one principled normalization: Zig names
//!    anonymous payload records with a compiler-internal instance
//!    counter (`Msg__struct_<N>`), which differs across modules even
//!    for identical declarations — in both lanes alike — so the digits
//!    are masked before comparison. No checker keys on those digits;
//!    every load-bearing spelling ("f64", "[]const u8", named types)
//!    is compared exactly.
//!
//! A fixture passing both is proof the reflecting seams (markup
//! engines, adapter, bridge, model-contract emit) cannot tell the
//! generated mirror from transpiler output. The suite also forces full
//! semantic analysis of every generated shim (dispatch stubs, snapshot
//! decoder, channel forwarders, helper methods) against the stub core's
//! exported symbol set, so the executable surface compiles and links
//! even though no compiled core exists to drive it yet.
//!
//! The markup fixture's sidecar is hand-written
//! (tests/sidecar/markup_fixture.contract.json) — independent ground
//! truth for the schema. The other fixtures' sidecars are extracted
//! from the transpiled modules at build time (tools/corewire/
//! extract.zig); the comparison stays honest because the reference side
//! is always the real transpiled module, so an extraction infidelity
//! surfaces here exactly like a generator one.

const std = @import("std");
const native_sdk = @import("native_sdk");
const lf = native_sdk.automation.layout_fingerprint;
const canvas = native_sdk.canvas;
const contract = canvas.ui_markup.contract;

const stub_core = @import("stub_core.zig");
const corewire_rt = @import("corewire_rt");

const ts_markup = @import("ts_markup_core");
const shim_markup = @import("shim_markup_core");
const shim_integer = @import("shim_integer_core");
const ts_host = @import("ts_host_core");
const shim_host = @import("shim_host_core");
const ts_soundboard = @import("ts_soundboard_core");
const shim_soundboard = @import("shim_soundboard_core");
const ts_monitor = @import("ts_monitor_core");
const shim_monitor = @import("shim_monitor_core");
const ts_ai_chat = @import("ts_ai_chat_core");
const shim_ai_chat = @import("shim_ai_chat_core");

const testing = std.testing;

fn expectDescribeIdentical(comptime ts: type, comptime shim: type) !void {
    try testing.expectEqualStrings(comptime lf.describe(ts.Model), comptime lf.describe(shim.Model));
    try testing.expectEqualStrings(comptime lf.describe(ts.Msg), comptime lf.describe(shim.Msg));
    // Same description, same hash — the fingerprint idiom the journal
    // and protocol identities ride.
    try testing.expectEqual(lf.hash(comptime lf.describe(ts.Model)), lf.hash(comptime lf.describe(shim.Model)));
    try testing.expectEqual(lf.hash(comptime lf.describe(ts.Msg)), lf.hash(comptime lf.describe(shim.Msg)));
}

/// Serialize a reflected contract the way the model-contract build step
/// does (source_hash stays 0: both sides reflect the same app sources,
/// and the hash is an emit-time input, not a reflection fact).
fn artifactBytes(comptime Model: type, comptime Msg: type, allocator: std.mem.Allocator) ![]const u8 {
    const described = comptime canvas.describeModelContract(Model, Msg);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try contract.writeArtifact(described, &out.writer);
    return allocator.dupe(u8, out.written());
}

/// Mask the compiler's anonymous-type instance counters
/// (`__struct_<digits>` -> `__struct_#`): the one spelling that differs
/// between two modules declaring identical anonymous records.
fn maskAnonCounters(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const marker = "__struct_";
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, marker)) |found| {
        const digits_start = found + marker.len;
        var digits_end = digits_start;
        while (digits_end < text.len and std.ascii.isDigit(text[digits_end])) digits_end += 1;
        if (digits_end == digits_start) {
            try out.appendSlice(allocator, text[index .. found + marker.len]);
            index = found + marker.len;
            continue;
        }
        try out.appendSlice(allocator, text[index..found]);
        try out.appendSlice(allocator, marker);
        try out.append(allocator, '#');
        index = digits_end;
    }
    try out.appendSlice(allocator, text[index..]);
    return out.items;
}

fn expectContractIdentical(comptime ts: type, comptime shim: type) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ts_artifact = try maskAnonCounters(arena, try artifactBytes(ts.Model, ts.Msg, arena));
    const shim_artifact = try maskAnonCounters(arena, try artifactBytes(shim.Model, shim.Msg, arena));
    try testing.expectEqualStrings(ts_artifact, shim_artifact);
}

// ------------------------------------------------------ markup fixture
// The bootstrap pair: hand-written sidecar, the full channel surface
// (frame/key/pinch/appearance/chrome/env), text-input and inline-record
// payloads, an optional scalar, a node-pointer iterable.

test "markup fixture: layout fingerprints are identical" {
    try expectDescribeIdentical(ts_markup, shim_markup);
}

test "markup fixture: model-contract artifacts are byte-identical" {
    try expectContractIdentical(ts_markup, shim_markup);
}

test "markup fixture: channel exports mirror the transpiled surface" {
    // The adapter wires channels from export presence; hold the two
    // lanes' export sets and arm-name constants equal.
    try testing.expectEqual(@hasDecl(ts_markup, "frameMsg"), @hasDecl(shim_markup, "frameMsg"));
    try testing.expectEqual(@hasDecl(ts_markup, "keyMsg"), @hasDecl(shim_markup, "keyMsg"));
    try testing.expectEqual(@hasDecl(ts_markup, "pinchMsg"), @hasDecl(shim_markup, "pinchMsg"));
    try testing.expectEqual(@hasDecl(ts_markup, "commandMsg"), @hasDecl(shim_markup, "commandMsg"));
    try testing.expectEqualStrings(ts_markup.appearanceMsg, shim_markup.appearanceMsg);
    try testing.expectEqualStrings(ts_markup.chromeMsg, shim_markup.chromeMsg);
    try testing.expectEqual(ts_markup.envMsgs.len, shim_markup.envMsgs.len);
    inline for (ts_markup.envMsgs, shim_markup.envMsgs) |expected, actual| {
        try testing.expectEqualStrings(expected.env, actual.env);
        try testing.expectEqualStrings(expected.msg, actual.msg);
    }
}

test "markup fixture: wire tags ride declaration order" {
    inline for (@typeInfo(ts_markup.Msg).@"union".fields, 0..) |field, tag| {
        try testing.expectEqualStrings(field.name, shim_markup.msg_tags[tag]);
    }
}

// -------------------------------------------------- host e2e fixture
// The effect-vocabulary stressor: 50 arms across every payload family
// (void, bytes, number f64/i64, number_bytes, and the audio/image/
// channel event records), enums in the model, an InitResult boot.

test "host fixture: layout fingerprints are identical" {
    try expectDescribeIdentical(ts_host, shim_host);
}

test "host fixture: model-contract artifacts are byte-identical" {
    try expectContractIdentical(ts_host, shim_host);
}

test "host fixture: the boot shape mirrors the transpiled surface" {
    // fixture.ts returns [model, cmd] from initialModel: both lanes
    // must expose the InitResult shape, not the bare pointer.
    try testing.expect(@typeInfo(@typeInfo(@TypeOf(ts_host.initialModel)).@"fn".return_type.?) == .@"struct");
    try testing.expect(@typeInfo(@typeInfo(@TypeOf(shim_host.initialModel)).@"fn".return_type.?) == .@"struct");
    try testing.expectEqual(@hasDecl(ts_host, "subscriptions"), @hasDecl(shim_host, "subscriptions"));
}

// -------------------------------------------------------- soundboard
// The helper-heavy real app: dozens of exported Model helpers
// (fn-backed scalars and iterables), optional model fields, chrome and
// env channels.

test "soundboard: layout fingerprints are identical" {
    try expectDescribeIdentical(ts_soundboard, shim_soundboard);
}

test "soundboard: model-contract artifacts are byte-identical" {
    try expectContractIdentical(ts_soundboard, shim_soundboard);
}

// ---------------------------------------------------- system monitor

test "system monitor: layout fingerprints are identical" {
    try expectDescribeIdentical(ts_monitor, shim_monitor);
}

test "system monitor: model-contract artifacts are byte-identical" {
    try expectContractIdentical(ts_monitor, shim_monitor);
}

// ------------------------------------------------------------ ai-chat
// The worked-example app: 13 helpers, a node-pointer draft record, a
// controlled scroll, text input, number_bytes fetch completion, three
// env channels.

test "ai-chat: layout fingerprints are identical" {
    try expectDescribeIdentical(ts_ai_chat, shim_ai_chat);
}

test "ai-chat: model-contract artifacts are byte-identical" {
    try expectContractIdentical(ts_ai_chat, shim_ai_chat);
}

test "ai-chat: helper methods keep the exported call surface" {
    // The markup engines bind helpers as Model methods; hold the two
    // lanes' method sets equal by name and shape (the contract
    // comparison already proves kinds — this pins presence).
    const ts_decls = @typeInfo(ts_ai_chat.Model).@"struct".decls;
    const shim_decls = @typeInfo(shim_ai_chat.Model).@"struct".decls;
    comptime var ts_fn_count = 0;
    comptime var shim_fn_count = 0;
    inline for (ts_decls) |decl| {
        if (@typeInfo(@TypeOf(@field(ts_ai_chat.Model, decl.name))) == .@"fn") ts_fn_count += 1;
    }
    inline for (shim_decls) |decl| {
        if (@typeInfo(@TypeOf(@field(shim_ai_chat.Model, decl.name))) == .@"fn") shim_fn_count += 1;
    }
    try testing.expectEqual(ts_fn_count, shim_fn_count);
    inline for (ts_decls) |decl| {
        if (@typeInfo(@TypeOf(@field(ts_ai_chat.Model, decl.name))) != .@"fn") continue;
        try testing.expect(@hasDecl(shim_ai_chat.Model, decl.name));
    }
}

// ---------------------------------------------- executable surface
// Force full semantic analysis and codegen of every generated shim —
// dispatch stubs, snapshot decoders, channel forwarders, helper
// methods — linked against the stub core's exported symbol set. No
// compiled core exists yet (the ABI is a draft), so these paths are
// compile- and link-proven here, not executed.

// ------------------------------------------- channel envelope axis
//
// The channel bytes envelope ([produced u8][tag u8][payload…]): a
// channel entry's whole result rides one bytes return, the compiled
// core packs it, the generated shim unpacks it. The packing side is
// proven at full behavioral depth by the compiled-core parity
// batteries (the generated facade IS the compiled core's entry); the
// unpacking side is executable here, driven against the stub core's
// test-settable envelope: the shim's channel entries gate on the
// produced flag and decode the payload back into the mirror value.

test "markup fixture: generated channel entries unpack the stub core's envelope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const saved = stub_core.stub_channel_envelope;
    defer stub_core.stub_channel_envelope = saved;
    defer shim_markup.rt.frameReset();

    const key = shim_markup.KeyEvent{ .key = "x", .shift = false, .control = false, .alt = false, .super = false };

    // The stub's default envelope says nothing was produced: the entry
    // gates to null.
    try testing.expect(shim_markup.keyMsg(key) == null);

    // A produced bare arm: header only, tag 0 = add.
    stub_core.stub_channel_envelope = &.{ 1, 0 };
    try testing.expect(shim_markup.keyMsg(key).? == .add);

    // A produced payload arm: the tail decodes as the arm's canonical
    // payload (toggle, i64-classed, tag 1).
    var toggle_envelope: std.ArrayListUnmanaged(u8) = .empty;
    try toggle_envelope.appendSlice(arena, &.{ 1, 1 });
    try toggle_envelope.appendSlice(arena, corewire_rt.encodeAlloc(i64, 2, arena));
    stub_core.stub_channel_envelope = toggle_envelope.items;
    try testing.expectEqual(@as(i64, 2), shim_markup.keyMsg(key).?.toggle);

    // A flattened record arm through the pinch entry (zoomed, tag 11).
    var zoom_envelope: std.ArrayListUnmanaged(u8) = .empty;
    try zoom_envelope.appendSlice(arena, &.{ 1, 11 });
    try zoom_envelope.appendSlice(arena, corewire_rt.encodeAlloc(@FieldType(shim_markup.Msg, "zoomed"), .{ .factor = 1.25, .windowId = 7, .fromBoard = true }, arena));
    stub_core.stub_channel_envelope = zoom_envelope.items;
    const zoomed = shim_markup.pinchMsg(.{ .windowId = 7, .label = "board", .phase = .change, .scale = 0.25, .x = 1, .y = 2 }).?;
    try testing.expectEqual(@as(f64, 1.25), zoomed.zoomed.factor);
    try testing.expect(zoomed.zoomed.fromBoard);
}

// ---------------------------------------------- integer-class fixture
//
// A hand-written sidecar attesting mixed integer classes
// (tests/sidecar/integer_fixture.contract.json): the generated mirror
// must decode each slot per its attested class — two's complement for
// i64, the unsigned twin for u64, f64 for every non-attested slot —
// over the compiler-provable extremes (+-(2^53 - 1)) and the full
// 8-byte wire range alike (the wire type is 8 bytes; the decoder is
// total over it).

test "integer fixture: mirror slots spell their attested classes" {
    try testing.expectEqual(i64, @FieldType(shim_integer.Model, "count"));
    try testing.expectEqual(u64, @FieldType(shim_integer.Model, "id"));
    try testing.expectEqual(f64, @FieldType(shim_integer.Model, "ratio"));
    try testing.expectEqual(?u64, @FieldType(shim_integer.Model, "cursor"));
    try testing.expectEqual(i64, @FieldType(shim_integer.Msg, "count_set"));
    try testing.expectEqual(u64, @FieldType(shim_integer.Msg, "id_set"));
    try testing.expectEqual(f64, @FieldType(shim_integer.Msg, "ratio_set"));
    try testing.expectEqual(u64, @FieldType(@FieldType(shim_integer.Msg, "sized"), "size"));
}

test "integer fixture: envelope payloads decode boundary and full-range integers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const saved = stub_core.stub_channel_envelope;
    defer stub_core.stub_channel_envelope = saved;
    defer shim_integer.rt.frameReset();

    const key = shim_integer.KeyEvent{ .key = "x", .shift = false, .control = false, .alt = false, .super = false };

    const Case = struct { envelope: []const u8, expected: shim_integer.Msg };
    const cases = [_]Case{
        // The compiler-provable extremes cross the i64-classed arm
        // (tag 1) exactly, sign included.
        .{ .envelope = &.{ 1, 1, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x1f, 0x00 }, .expected = .{ .count_set = 9007199254740991 } },
        .{ .envelope = &.{ 1, 1, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0, 0xff }, .expected = .{ .count_set = -9007199254740991 } },
        // The u64-attested arm (tag 2) reads the same 8 bytes unsigned:
        // the all-ones pattern is u64 max, never -1.
        .{ .envelope = &.{ 1, 2, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x1f, 0x00 }, .expected = .{ .id_set = 9007199254740991 } },
        .{ .envelope = &.{ 1, 2, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, .expected = .{ .id_set = 18446744073709551615 } },
        // The number_bytes number field follows its own attestation.
        .{ .envelope = &.{ 1, 4, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x1f, 0x00, 3, 0, 0, 0, 'r', 'o', 'w' }, .expected = .{ .sized = .{ .size = 9007199254740991, .label = "row" } } },
    };
    for (cases) |case| {
        stub_core.stub_channel_envelope = case.envelope;
        const decoded = shim_integer.keyMsg(key) orelse return error.TestUnexpectedResult;
        // Decoded value and re-encoded bytes both match: the mirror
        // round-trips the wire exactly.
        try testing.expectEqualSlices(
            u8,
            corewire_rt.encodeAlloc(shim_integer.Msg, case.expected, arena),
            corewire_rt.encodeAlloc(shim_integer.Msg, decoded, arena),
        );
        try testing.expectEqualSlices(u8, case.envelope[1..], corewire_rt.encodeAlloc(shim_integer.Msg, decoded, arena));
    }
}

test "integer fixture: dispatch payloads encode byte-exactly against hand-computed vectors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The canonical union encoding ([arm u8][payload…]) of each
    // integer-carrying arm, against hand-computed little-endian bytes.
    try testing.expectEqualSlices(
        u8,
        &.{ 1, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0, 0xff },
        corewire_rt.encodeAlloc(shim_integer.Msg, .{ .count_set = -9007199254740991 }, arena),
    );
    try testing.expectEqualSlices(
        u8,
        &.{ 2, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
        corewire_rt.encodeAlloc(shim_integer.Msg, .{ .id_set = 18446744073709551615 }, arena),
    );
    try testing.expectEqualSlices(
        u8,
        &.{ 4, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x1f, 0x00, 2, 0, 0, 0, 'i', 'd' },
        corewire_rt.encodeAlloc(shim_integer.Msg, .{ .sized = .{ .size = 9007199254740991, .label = "id" } }, arena),
    );
}

test "integer fixture: model snapshots decode per-slot classes from raw bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A hand-laid snapshot of the fixture's model (count i64, id u64,
    // ratio f64, cursor optional u64), decoded through the mirror's own
    // declared types: each slot reads its 8 bytes per its class.
    const snapshot = [_]u8{
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0, 0xff, // count = -(2^53 - 1)
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // id = u64 max
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x3f, // ratio = 1.5
        0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x1f, 0x00, // cursor = 2^53 - 1
    };
    const model = corewire_rt.decodeExact(shim_integer.Model, &snapshot, arena);
    try testing.expectEqual(@as(i64, -9007199254740991), model.count);
    try testing.expectEqual(@as(u64, 18446744073709551615), model.id);
    try testing.expectEqual(@as(f64, 1.5), model.ratio);
    try testing.expectEqual(@as(?u64, 9007199254740991), model.cursor);
    // Re-encoding reproduces the wire bytes exactly.
    try testing.expectEqualSlices(u8, &snapshot, corewire_rt.encodeAlloc(shim_integer.Model, model, arena));
}

/// Reference every public declaration, recursing into declared types
/// (all of a shim's public type declarations are its own, so the walk
/// never leaves the generated module).
fn refAllDeclsRecursive(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}

test "every generated shim fully analyzes and links against the ABI" {
    refAllDeclsRecursive(shim_markup);
    refAllDeclsRecursive(shim_integer);
    refAllDeclsRecursive(shim_host);
    refAllDeclsRecursive(shim_soundboard);
    refAllDeclsRecursive(shim_monitor);
    refAllDeclsRecursive(shim_ai_chat);
    testing.refAllDecls(stub_core);
}
