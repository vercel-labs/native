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

const ts_markup = @import("ts_markup_core");
const shim_markup = @import("shim_markup_core");
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
