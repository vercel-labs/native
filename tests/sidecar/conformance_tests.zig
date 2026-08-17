//! Sidecar-shim conformance: for every core in the ts-core corpus,
//! corewire generates the mirror from that core's contract sidecar —
//! the frontend-emitted document for the compiled fixtures, plus three
//! hand-written ground truths for the schema itself — and this suite
//! validates the generated surface:
//!
//! 1. The markup fixture's mirror (over the COMMITTED hand-written
//!    sidecar, tests/sidecar/markup_fixture.contract.json) keeps its
//!    pinned layout fingerprints — the describe hashes the journal and
//!    wire identities ride — and the sidecar's declared channel/export
//!    surface and declaration-order wire tags.
//! 2. The integer fixture's mirror decodes every slot per its attested
//!    class over hand-computed wire vectors.
//! 3. A committed 160-arm sidecar proves generated Msg mirrors compile
//!    without an app- or test-side eval-branch quota.
//! 4. Every generated shim (dispatch stubs, snapshot decoder, channel
//!    forwarders, helper methods) fully analyzes and links against the
//!    stub core's exported symbol set — the executable surface is
//!    compile- and link-proven for the whole corpus without driving
//!    the fixtures' real archives.
//!
//! Behavioral truth over the REAL compiled cores lives in the e2e
//! batteries (tests/ts-core, one archive per binary) and the ABI-law
//! suite (external_core_abi_tests.zig); this suite is the generator's
//! reflection fence.

const std = @import("std");
const native_sdk = @import("native_sdk");
const lf = native_sdk.automation.layout_fingerprint;

const stub_core = @import("stub_core.zig");
const corewire_rt = @import("corewire_rt");

const shim_markup = @import("shim_markup_core");
const shim_wide = @import("shim_wide_core");
const shim_integer = @import("shim_integer_core");
const shim_host = @import("shim_host_core");
const shim_kanban = @import("shim_kanban_core");
const shim_soundboard = @import("shim_soundboard_core");
const shim_monitor = @import("shim_monitor_core");
const shim_ai_chat = @import("shim_ai_chat_core");

const testing = std.testing;
const WideAdapter = native_sdk.TsUiApp(shim_wide);

// --------------------------------------------------------- wide Msg guard
//
// Compile-cost guard: a legal 160-arm TypeScript-core contract must compile
// through corewire without this test (or any app) raising
// `@setEvalBranchQuota`. The arm names are deliberately production-shaped,
// because comptime string comparison cost scales with their total bytes.

test "wide Msg mirror compiles and canonical union scans reach the final arm" {
    comptime WideAdapter.validatePersistRoutes(.{
        .ok = "quota_probe_message_arm_157_with_realistic_name",
        .none = "quota_probe_message_arm_158_with_realistic_name",
        .err = "quota_probe_message_arm_159_with_realistic_name",
    });
    try testing.expectEqual(@as(usize, 160), shim_wide.msg_tags.len);
    try testing.expectEqualStrings(
        "quota_probe_message_arm_159_with_realistic_name",
        shim_wide.msg_tags[159],
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value: shim_wide.Msg = .{ .quota_probe_message_arm_159_with_realistic_name = "wide" };
    const encoded = corewire_rt.encodeAlloc(shim_wide.Msg, value, arena);
    try testing.expectEqualSlices(u8, &.{ 159, 4, 0, 0, 0, 'w', 'i', 'd', 'e' }, encoded);
    const decoded = corewire_rt.decodeExact(shim_wide.Msg, encoded, arena);
    try testing.expectEqualStrings("wide", decoded.quota_probe_message_arm_159_with_realistic_name);
}

// ------------------------------------------------------ markup fixture
// The bootstrap mirror: hand-written sidecar (independent ground truth
// for the schema), the full channel surface (frame/key/pinch/drop/
// appearance/chrome/env), text-input and inline-record payloads, an
// optional scalar, a node-pointer iterable.

test "markup fixture: mirror layout fingerprints stay pinned" {
    // Golden fingerprint hashes of the mirror's Model and Msg describe
    // strings over the COMMITTED sidecar — the hashes the journal and
    // protocol identities ride. They move only when the sidecar or the
    // generator's projection rules change; review the printed describe
    // string before re-pinning.
    const model_desc = comptime lf.describe(shim_markup.Model);
    const msg_desc = comptime lf.describe(shim_markup.Msg);
    testing.expectEqual(@as(u64, 0x26243886fcbe6b9f), lf.hash(model_desc)) catch |err| {
        std.debug.print("mirror Model describe:\n{s}\n", .{model_desc});
        return err;
    };
    testing.expectEqual(@as(u64, 0x3b7007b5499e1811), lf.hash(msg_desc)) catch |err| {
        std.debug.print("mirror Msg describe:\n{s}\n", .{msg_desc});
        return err;
    };
}

test "markup fixture: the mirror declares the sidecar's channel surface" {
    // The adapter wires channels from export presence; pin the export
    // set and arm-name constants the committed sidecar declares.
    try testing.expect(@hasDecl(shim_markup, "frameMsg"));
    try testing.expect(@hasDecl(shim_markup, "keyMsg"));
    try testing.expect(@hasDecl(shim_markup, "pinchMsg"));
    try testing.expect(@hasDecl(shim_markup, "dropMsg"));
    try testing.expect(!@hasDecl(shim_markup, "commandMsg"));
    try testing.expectEqualStrings("appearance_changed", shim_markup.appearanceMsg);
    try testing.expectEqualStrings("chrome_changed", shim_markup.chromeMsg);
    try testing.expectEqual(1, shim_markup.envMsgs.len);
    try testing.expectEqualStrings("TS_BOARD_BANNER", shim_markup.envMsgs[0].env);
    try testing.expectEqualStrings("banner_set", shim_markup.envMsgs[0].msg);
}

test "markup fixture: wire tags ride the sidecar's declaration order" {
    // The committed sidecar's msg section, in order — the tag authority
    // every dispatch entry indexes into.
    const expected_tags = [_][]const u8{
        "add",            "toggle",  "pick",               "cycle",          "clear",
        "stamp",          "stamped", "hover_row",          "hover_off",      "draft_edit",
        "canvas_resized", "zoomed",  "appearance_changed", "chrome_changed", "banner_set",
    };
    try testing.expectEqual(expected_tags.len, shim_markup.msg_tags.len);
    inline for (expected_tags, 0..) |expected, tag| {
        try testing.expectEqualStrings(expected, shim_markup.msg_tags[tag]);
        try testing.expectEqualStrings(expected, @typeInfo(shim_markup.Msg).@"union".fields[tag].name);
    }
}

// -------------------------------------------------- host e2e fixture
// The effect-vocabulary stressor: 50 arms across every payload family
// (void, bytes, number f64/i64, number_bytes, and the audio/image/
// channel event records), enums in the model, an InitResult boot.

test "host fixture: the mirror declares the boot and subscription shape" {
    // fixture.ts returns [model, cmd] from initialModel and exports
    // subscriptions: the mirror must expose the InitResult shape (not
    // the bare pointer) and the subscription entry.
    try testing.expect(@typeInfo(@typeInfo(@TypeOf(shim_host.initialModel)).@"fn".return_type.?) == .@"struct");
    try testing.expect(@hasDecl(shim_host, "subscriptions"));
}

// ------------------------------------------------------------- kanban

test "kanban: model-only updates and the native drop channel stay reflected" {
    try testing.expect(@hasDecl(shim_kanban, "dropMsg"));
    try testing.expect(@hasDecl(shim_kanban.Model, "todoCards"));
    try testing.expect(@hasDecl(shim_kanban.Model, "doingCards"));
    try testing.expect(@hasDecl(shim_kanban.Model, "doneCards"));
    try testing.expect(@typeInfo(@typeInfo(@TypeOf(shim_kanban.update)).@"fn".return_type.?) == .pointer);
}

// ------------------------------------------------------------ ai-chat
// The worked-example app: helper-heavy, a node-pointer draft record, a
// controlled scroll, text input, number_bytes fetch completion, three
// env channels.

test "ai-chat: helper methods keep the exported call surface" {
    // The markup engines bind helpers as Model methods; pin the two
    // helpers the shipping markup and the e2e battery lean on (the
    // battery executes them against the real archive).
    try testing.expect(@hasDecl(shim_ai_chat.Model, "draftText"));
    try testing.expect(@hasDecl(shim_ai_chat.Model, "unconfigured"));
}

// ------------------------------------------- channel envelope axis
//
// The channel bytes envelope ([produced u8][tag u8][payload…]): a
// channel entry's whole result rides one bytes return, the compiled
// core packs it, the generated shim unpacks it. The packing side is
// proven at full behavioral depth by the e2e batteries and the ABI-law
// suite (the generated facade IS the compiled core's entry); the
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

    // The drop entry accepts its nested optional/sequence input and the
    // same envelope decoder remains the one result path.
    const paths = [_][]const u8{"/tmp/report.txt"};
    const dropped = shim_markup.dropMsg(.{
        .windowId = 1,
        .viewLabel = "board",
        .point = .{ .x = 12.5, .y = 24.25 },
        .paths = &paths,
    }).?;
    try testing.expectEqual(@as(f64, 1.25), dropped.zoomed.factor);
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
    refAllDeclsRecursive(shim_wide);
    refAllDeclsRecursive(shim_integer);
    refAllDeclsRecursive(shim_host);
    refAllDeclsRecursive(shim_kanban);
    refAllDeclsRecursive(shim_soundboard);
    refAllDeclsRecursive(shim_monitor);
    refAllDeclsRecursive(shim_ai_chat);
    testing.refAllDecls(stub_core);
}
