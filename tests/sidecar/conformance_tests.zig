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
const facade_markup = @import("facade_markup_core");
const ts_host = @import("ts_host_core");
const shim_host = @import("shim_host_core");
const facade_host = @import("facade_host_core");
const ts_soundboard = @import("ts_soundboard_core");
const shim_soundboard = @import("shim_soundboard_core");
const facade_soundboard = @import("facade_soundboard_core");
const ts_monitor = @import("ts_monitor_core");
const shim_monitor = @import("shim_monitor_core");
const facade_monitor = @import("facade_monitor_core");
const ts_ai_chat = @import("ts_ai_chat_core");
const shim_ai_chat = @import("shim_ai_chat_core");
const facade_ai_chat = @import("facade_ai_chat_core");

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

// ------------------------------------------------ facade parity axis
//
// The third comparison: the sidecar's TypeScript projection
// (core_facade.ts), compiled through the shipped transpiler (the
// compile IS the subset-acceptance proof), must produce the exact
// canonical bytes the host's decoder expects. The facade encodes its
// deterministic sample and zero models in compiled subset arithmetic;
// the reference bytes come from the shared canonical encoder
// (corewire_rt.encodeAlloc) over the SHIM module's mirror type — the
// sidecar-classed layout — after a by-name value conversion (the
// facade compile's own number classes are inference-decided and may
// legally differ; the bytes must not).

/// Mirror-value conversion by name (tests/sidecar/mirror_value.zig),
/// shared with the compiled-core behavior-parity suite.
const convertValue = @import("mirror_value.zig").convertValue;

/// The facade's compiled snapshot encoder must byte-match the canonical
/// encoder over the sidecar-classed mirror layout, for both the zero
/// model and the deterministic sample.
fn expectSnapshotParity(comptime facade: type, comptime shim: type) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    facade.rt.resetAll();
    const models = [_]*const facade.Model{ facade.initialModel(), facade.nsc_core_sample_model() };
    for (models) |model| {
        const facade_bytes = facade.nsc_core_model_snapshot(1, model);
        const converted = try convertValue(shim.Model, model, arena);
        const canonical = corewire_rt.encodeAlloc(shim.Model, converted, arena);
        try testing.expectEqualSlices(u8, canonical, facade_bytes);
    }
    facade.rt.resetAll();
}

fn expectScalarProbeParity(comptime facade: type) !void {
    const f64_values = [_]f64{
        0.0,     -0.0,                    1.0,                    -1.0,               0.5,                 -2.75,
        0.1,     1.5625,                  1e300,                  -1e300,             1e-300,              5e-324,
        -5e-324, 2.2250738585072014e-308, 1.7976931348623157e308, 9007199254740991.0, -9007199254740991.0, 3.141592653589793,
    };
    for (f64_values) |value| {
        facade.rt.frameReset();
        const encoded = facade.nsc_core_probe_f64(value);
        var expected: [8]u8 = undefined;
        std.mem.writeInt(u64, &expected, @bitCast(value), .little);
        try testing.expectEqualSlices(u8, &expected, encoded);
    }
    // The infinities and the canonical quiet NaN.
    const specials = [_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) };
    for (specials) |value| {
        facade.rt.frameReset();
        const encoded = facade.nsc_core_probe_f64(value);
        var expected: [8]u8 = undefined;
        std.mem.writeInt(u64, &expected, @bitCast(value), .little);
        try testing.expectEqualSlices(u8, &expected, encoded);
    }
    // Non-canonical NaNs (sign, payload bits) canonicalize to the one
    // quiet pattern in BOTH encoders — payload bits are not values.
    const canonical_nan = [_]u8{ 0, 0, 0, 0, 0, 0, 0xf8, 0x7f };
    const odd_nans = [_]f64{ -std.math.nan(f64), @bitCast(@as(u64, 0x7ff800000000beef)) };
    for (odd_nans) |value| {
        facade.rt.frameReset();
        try testing.expectEqualSlices(u8, &canonical_nan, facade.nsc_core_probe_f64(value));
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        try testing.expectEqualSlices(u8, &canonical_nan, corewire_rt.encodeAlloc(f64, value, arena_state.allocator()));
    }
    const i64_values = [_]i64{ 0, 1, -1, 255, 256, -256, 65535, -65536, 42424242, -1234567890123, 9007199254740991, -9007199254740991 };
    for (i64_values) |value| {
        facade.rt.frameReset();
        const encoded = facade.nsc_core_probe_i64(@floatFromInt(value));
        var expected: [8]u8 = undefined;
        std.mem.writeInt(u64, &expected, @bitCast(value), .little);
        try testing.expectEqualSlices(u8, &expected, encoded);
    }
    facade.rt.frameReset();
}

test "markup fixture: facade scalar encodings match native bit patterns" {
    try expectScalarProbeParity(facade_markup);
}

test "markup fixture: facade snapshots byte-match the canonical encoder" {
    try expectSnapshotParity(facade_markup, shim_markup);
}

test "markup fixture: facade wire constructors carry declaration-order tags" {
    // The constructor family is the dispatch-table projection: the arm
    // a constructor builds must sit at its wire tag in the facade's own
    // compiled union.
    const add = facade_markup.nsc_core_msg_add();
    try testing.expectEqual(@as(usize, 0), @intFromEnum(std.meta.activeTag(add)));
    const zoomed = facade_markup.nsc_core_msg_zoomed(1.5, 7, true);
    // zoomed sits at tag 11: the hover containment pair (hover_row,
    // hover_off) declares ahead of it in the fixture's Msg union.
    try testing.expectEqual(@as(usize, 11), @intFromEnum(std.meta.activeTag(zoomed)));
    try testing.expectEqual(@as(f64, 1.5), zoomed.zoomed.factor);
    try testing.expect(zoomed.zoomed.fromBoard);
    try testing.expectEqual(@as(usize, 0), facade_markup.nsc_core_tag_add);
    try testing.expectEqual(@as(usize, 11), facade_markup.nsc_core_tag_zoomed);
}

test "host fixture: facade scalar encodings match native bit patterns" {
    try expectScalarProbeParity(facade_host);
}

test "host fixture: facade snapshots byte-match the canonical encoder" {
    try expectSnapshotParity(facade_host, shim_host);
}

test "soundboard: facade snapshots byte-match the canonical encoder" {
    try expectSnapshotParity(facade_soundboard, shim_soundboard);
}

test "system monitor: facade snapshots byte-match the canonical encoder" {
    try expectSnapshotParity(facade_monitor, shim_monitor);
}

test "ai-chat: facade snapshots byte-match the canonical encoder" {
    try expectSnapshotParity(facade_ai_chat, shim_ai_chat);
}

// ------------------------------------------- channel envelope axis
//
// The channel bytes envelope ([produced u8][tag u8][payload…]): a
// channel entry's whole result rides one bytes return, the compiled
// facade packs it, the generated shim unpacks it. Two executable
// proofs, one per side:
//
//   - the facade's packed envelope is [1] ++ the canonical union
//     encoding of the produced message (the envelope tail IS that
//     encoding: tag byte = declaration-order arm index, payload = the
//     arm's canonical bytes) — compared against the host's canonical
//     encoder over the shim's mirror union;
//   - the generated shim's channel entries, driven against the stub
//     core's test-settable envelope, gate on the produced flag and
//     decode the payload back into the mirror value.

test "markup fixture: facade channel envelopes carry the canonical message bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    facade_markup.rt.resetAll();
    defer facade_markup.rt.resetAll();

    // Nothing produced: exactly the two header bytes.
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, facade_markup.nsc_core_key_msg(null));

    // Produced arms across the payload families the fixture carries: a
    // bare arm, an integer-classed number, bytes, a flattened record,
    // and a flattened record with an enum member.
    {
        const envelope = facade_markup.nsc_core_key_msg(facade_markup.nsc_core_msg_add());
        try testing.expectEqual(@as(u8, 1), envelope[0]);
        try testing.expectEqualSlices(u8, corewire_rt.encodeAlloc(shim_markup.Msg, .add, arena), envelope[1..]);
    }
    {
        const envelope = facade_markup.nsc_core_key_msg(facade_markup.nsc_core_msg_toggle(2));
        try testing.expectEqual(@as(u8, 1), envelope[0]);
        try testing.expectEqualSlices(u8, corewire_rt.encodeAlloc(shim_markup.Msg, .{ .toggle = 2 }, arena), envelope[1..]);
    }
    {
        const envelope = facade_markup.nsc_core_key_msg(facade_markup.nsc_core_msg_banner_set("parity"));
        try testing.expectEqual(@as(u8, 1), envelope[0]);
        try testing.expectEqualSlices(u8, corewire_rt.encodeAlloc(shim_markup.Msg, .{ .banner_set = "parity" }, arena), envelope[1..]);
    }
    {
        const envelope = facade_markup.nsc_core_pinch_msg(facade_markup.nsc_core_msg_zoomed(1.25, 7, true));
        try testing.expectEqual(@as(u8, 1), envelope[0]);
        try testing.expectEqualSlices(u8, corewire_rt.encodeAlloc(shim_markup.Msg, .{ .zoomed = .{ .factor = 1.25, .windowId = 7, .fromBoard = true } }, arena), envelope[1..]);
    }
    {
        const envelope = facade_markup.nsc_core_frame_msg(facade_markup.nsc_core_msg_appearance_changed(.dark, false, true));
        try testing.expectEqual(@as(u8, 1), envelope[0]);
        try testing.expectEqualSlices(u8, corewire_rt.encodeAlloc(shim_markup.Msg, .{ .appearance_changed = .{ .colorScheme = .dark, .reduceMotion = false, .highContrast = true } }, arena), envelope[1..]);
    }

    // Every wired entry routes through one packer: identical bytes for
    // one message, and the unwired command channel stays out of the
    // facade surface entirely.
    const msg = facade_markup.nsc_core_msg_toggle(2);
    try testing.expectEqualSlices(u8, facade_markup.nsc_core_key_msg(msg), facade_markup.nsc_core_frame_msg(msg));
    try testing.expectEqualSlices(u8, facade_markup.nsc_core_frame_msg(msg), facade_markup.nsc_core_pinch_msg(msg));
    try testing.expect(!@hasDecl(facade_markup, "nsc_core_command_msg"));
}

test "soundboard: facade channel envelopes carry the canonical message bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    facade_soundboard.rt.resetAll();
    defer facade_soundboard.rt.resetAll();

    try testing.expectEqualSlices(u8, &.{ 0, 0 }, facade_soundboard.nsc_core_frame_msg(null));
    {
        const envelope = facade_soundboard.nsc_core_key_msg(facade_soundboard.nsc_core_msg_toggle_play());
        try testing.expectEqual(@as(u8, 1), envelope[0]);
        try testing.expectEqualSlices(u8, corewire_rt.encodeAlloc(shim_soundboard.Msg, .toggle_play, arena), envelope[1..]);
    }
    {
        const envelope = facade_soundboard.nsc_core_frame_msg(facade_soundboard.nsc_core_msg_canvas_resized(640));
        try testing.expectEqual(@as(u8, 1), envelope[0]);
        try testing.expectEqualSlices(u8, corewire_rt.encodeAlloc(shim_soundboard.Msg, .{ .canvas_resized = 640 }, arena), envelope[1..]);
    }
}

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
    refAllDeclsRecursive(shim_host);
    refAllDeclsRecursive(shim_soundboard);
    refAllDeclsRecursive(shim_monitor);
    refAllDeclsRecursive(shim_ai_chat);
    testing.refAllDecls(stub_core);
}
