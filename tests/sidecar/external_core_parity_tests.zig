//! Behavior parity against a REAL compiled core: the build links a
//! caller-supplied compiled-core archive (NATIVE_SDK_EXTERNAL_CORE_ARCHIVE,
//! one or more link inputs joined by the platform path delimiter, which
//! together must export the markup fixture's attested symbol set under
//! the canonical prefix) into this binary, and the suite drives one
//! scripted message sequence through BOTH lanes:
//!
//!   - the transpiler lane: tests/ts-core/markup_fixture.ts emitted by
//!     the repo's own transpiler (`ts_core`), and
//!   - the compiled-core lane: corewire's generated mirror
//!     (`shim_core`) dispatching into the linked archive through the
//!     C ABI bindings,
//!
//! comparing every observable byte surface per cycle: the command
//! bytes each dispatch returns, the committed-model snapshot (the
//! archive's raw snapshot bytes against the canonical encoding of the
//! transpiler lane's committed model), and the subscription bytes.
//! The suite also pins the ABI's collect invariant on the archive
//! side: a collect between dispatches leaves the observable snapshot
//! byte-identical.
//!
//! The channel entries ride the bytes envelope ([produced u8][tag u8]
//! [payload…]): the second test drives both lanes' channel functions
//! over gating and producing events — the archive's entries return the
//! envelope, the generated mirror unpacks it — and every produced
//! message dispatches through both lanes as a full cycle.
//!
//! The conformance suite (conformance_tests.zig) proves the two lanes'
//! REFLECTION surfaces identical with no compiled core present; this
//! suite is the executable half, and only builds when a caller
//! supplies the archive — `zig build test` skips it otherwise.

const std = @import("std");
const corewire_rt = @import("corewire_rt");
const core_abi = @import("core_abi");
const convertValue = @import("mirror_value.zig").convertValue;

const ts_core = @import("ts_core");
const shim_core = @import("shim_core");

const abi = core_abi.Bindings("nsc_core_");
const testing = std.testing;

/// The archive's raw committed-model snapshot bytes (result-arena
/// resident: read and compare before any frame reset or collect).
fn rawSnapshot() []const u8 {
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    abi.model_snapshot(&ptr, &len);
    return ptr[0..len];
}

fn rawSubscriptions() []const u8 {
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    abi.subscriptions(&ptr, &len);
    return ptr[0..len];
}

/// The transpiler lane's committed model, re-expressed in the mirror's
/// sidecar-classed layout and canonically encoded — the reference bytes
/// the archive's snapshot must equal.
fn referenceSnapshot(model: *const ts_core.Model, arena: std.mem.Allocator) ![]const u8 {
    const converted = try convertValue(shim_core.Model, model, arena);
    return corewire_rt.encodeAlloc(shim_core.Model, converted, arena);
}

/// The scripted sequence: every dispatch entry class the fixture's
/// contract declares — bare arms, i64- and f64-classed numbers, bytes,
/// the text-input union (each payload family), and the three record
/// arms — plus the one command-producing arm (`stamp`, whose cycle
/// returns the `now` op's two wire bytes).
const script = [_]shim_core.Msg{
    .add,
    .add,
    .{ .toggle = 2 },
    .{ .pick = 2 },
    .add,
    .cycle,
    .{ .banner_set = "parity" },
    .{ .draft_edit = .{ .insert_text = "hi" } },
    .{ .draft_edit = .delete_backward },
    .{ .draft_edit = .{ .move_caret = .{ .direction = .next_word, .extend = true } } },
    .{ .draft_edit = .{ .set_selection = .{ .anchor = 1, .focus = -2 } } },
    .{ .draft_edit = .{ .set_composition = .{ .text = "ab", .cursor = 1 } } },
    .{ .draft_edit = .{ .set_composition = .{ .text = "", .cursor = null } } },
    .{ .draft_edit = .clear },
    .{ .canvas_resized = 800 },
    .{ .zoomed = .{ .factor = 1.25, .windowId = 7, .fromBoard = true } },
    .{ .appearance_changed = .{ .colorScheme = .dark, .reduceMotion = false, .highContrast = true } },
    .{ .chrome_changed = .{ .insets = .{ .top = 28, .right = 0, .bottom = 0, .left = 0 }, .buttons = .{ .x = 8, .y = 6, .width = 52, .height = 16 }, .tabsProjected = false } },
    .stamp,
    .{ .stamped = 42.5 },
    .{ .toggle = 1 },
    .cycle,
    .clear,
};

test "a compiled core archive matches the transpiler lane byte-for-byte over the scripted cycle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Boot both lanes. The mirror's initialModel runs the full boot
    // fence against the archive (identity getters, sink, init); the
    // fixture's contract declares no boot command, so the archive's
    // boot_cmd buffer must be empty.
    var ts_model = ts_core.commitModelRoot(ts_core.initialModel());
    var shim_model = shim_core.commitModelRoot(shim_core.initialModel());
    {
        var boot_ptr: [*]const u8 = undefined;
        var boot_len: usize = 0;
        abi.boot_cmd(&boot_ptr, &boot_len);
        try testing.expectEqualSlices(u8, "", boot_ptr[0..boot_len]);
    }
    try testing.expectEqualSlices(u8, try referenceSnapshot(ts_model, arena), rawSnapshot());
    // The decoded mirror root re-encodes to the same bytes: decode
    // fidelity over the boot snapshot.
    try testing.expectEqualSlices(u8, rawSnapshot(), corewire_rt.encodeAlloc(shim_core.Model, shim_model.*, arena));
    ts_core.rt.frameReset();
    shim_core.rt.frameReset();

    for (script, 0..) |msg, step| {
        // One cycle per lane, the host adapter's ordering: update,
        // commit, consume the command bytes, then frame reset.
        const ts_msg = try convertValue(ts_core.Msg, msg, arena);
        const ts_out = ts_core.update(ts_model, ts_msg);
        ts_model = ts_core.commitModelRoot(ts_out.model);
        const shim_out = shim_core.update(shim_model, msg);
        shim_model = shim_core.commitModelRoot(shim_out.model);

        testing.expectEqualSlices(u8, ts_out.cmd, shim_out.cmd) catch |err| {
            std.debug.print("command bytes diverge at script step {d} ({s})\n", .{ step, @tagName(msg) });
            return err;
        };
        const reference = try referenceSnapshot(ts_model, arena);
        testing.expectEqualSlices(u8, reference, rawSnapshot()) catch |err| {
            std.debug.print("snapshot bytes diverge at script step {d} ({s})\n", .{ step, @tagName(msg) });
            return err;
        };

        // Between dispatches, a collect must leave the observable model
        // untouched (the ABI's collect invariant), and the fixture's
        // contract declares no subscriptions, so the buffer stays empty.
        if (step % 3 == 2) {
            abi.collect();
            testing.expectEqualSlices(u8, reference, rawSnapshot()) catch |err| {
                std.debug.print("collect changed the observable snapshot at script step {d} ({s})\n", .{ step, @tagName(msg) });
                return err;
            };
        }
        try testing.expectEqualSlices(u8, "", rawSubscriptions());

        ts_core.rt.frameReset();
        shim_core.rt.frameReset();
    }

    // Deterministic re-init: a second boot lands both lanes back on the
    // boot bytes.
    ts_core.rt.resetAll();
    shim_core.rt.resetAll();
    ts_model = ts_core.commitModelRoot(ts_core.initialModel());
    shim_model = shim_core.commitModelRoot(shim_core.initialModel());
    try testing.expectEqualSlices(u8, try referenceSnapshot(ts_model, arena), rawSnapshot());
    ts_core.rt.frameReset();
    shim_core.rt.frameReset();
}

/// One dispatch cycle in both lanes over one channel-produced message:
/// the two lanes' messages must be one value (compared by canonical
/// bytes in the mirror's layout), and the cycle's command and snapshot
/// bytes must match — a channel Msg round-trips through the matching
/// dispatch entry byte-identically.
fn channelParityCycle(
    arena: std.mem.Allocator,
    ts_model: *const ts_core.Model,
    shim_model: *const shim_core.Model,
    ts_msg: ts_core.Msg,
    shim_msg: shim_core.Msg,
) !struct { ts: *const ts_core.Model, shim: *const shim_core.Model } {
    const converted = try convertValue(shim_core.Msg, ts_msg, arena);
    try testing.expectEqualSlices(
        u8,
        corewire_rt.encodeAlloc(shim_core.Msg, converted, arena),
        corewire_rt.encodeAlloc(shim_core.Msg, shim_msg, arena),
    );
    const ts_out = ts_core.update(ts_model, ts_msg);
    const next_ts = ts_core.commitModelRoot(ts_out.model);
    const shim_out = shim_core.update(shim_model, shim_msg);
    const next_shim = shim_core.commitModelRoot(shim_out.model);
    try testing.expectEqualSlices(u8, ts_out.cmd, shim_out.cmd);
    try testing.expectEqualSlices(u8, try referenceSnapshot(next_ts, arena), rawSnapshot());
    ts_core.rt.frameReset();
    shim_core.rt.frameReset();
    return .{ .ts = next_ts, .shim = next_shim };
}

test "channel entries match the transpiler lane through the bytes envelope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A fresh boot in both lanes (init is the deterministic re-init
    // seam, so this test stands alone).
    ts_core.rt.resetAll();
    shim_core.rt.resetAll();
    var ts_model = ts_core.commitModelRoot(ts_core.initialModel());
    var shim_model = shim_core.commitModelRoot(shim_core.initialModel());
    ts_core.rt.frameReset();
    shim_core.rt.frameReset();

    // Gating parity: a chorded key, an unchanged frame, and a begin
    // pinch produce nothing in either lane (the archive's entry returns
    // the two-byte nothing-produced envelope).
    try testing.expect(ts_core.keyMsg(.{ .key = "space", .shift = false, .control = true, .alt = false, .super = false }) == null);
    try testing.expect(shim_core.keyMsg(.{ .key = "space", .shift = false, .control = true, .alt = false, .super = false }) == null);
    try testing.expect(ts_core.frameMsg(ts_model, .{ .width = 0, .height = 600, .timestampMs = 16, .intervalMs = 16 }) == null);
    try testing.expect(shim_core.frameMsg(shim_model, .{ .width = 0, .height = 600, .timestampMs = 16, .intervalMs = 16 }) == null);
    try testing.expect(ts_core.pinchMsg(.{ .windowId = 7, .label = "ts-markup-canvas", .phase = .begin, .scale = 0, .x = 1, .y = 2 }) == null);
    try testing.expect(shim_core.pinchMsg(.{ .windowId = 7, .label = "ts-markup-canvas", .phase = .begin, .scale = 0, .x = 1, .y = 2 }) == null);

    // The presented-frame channel produces the resize at boot width,
    // and the dispatched cycle updates the model so the same frame then
    // gates (the idle law, proven across the round trip).
    {
        const ts_msg = ts_core.frameMsg(ts_model, .{ .width = 800, .height = 600, .timestampMs = 16, .intervalMs = 16 }) orelse return error.TestUnexpectedResult;
        const shim_msg = shim_core.frameMsg(shim_model, .{ .width = 800, .height = 600, .timestampMs = 16, .intervalMs = 16 }) orelse return error.TestUnexpectedResult;
        const next = try channelParityCycle(arena, ts_model, shim_model, ts_msg, shim_msg);
        ts_model = next.ts;
        shim_model = next.shim;
        try testing.expect(ts_core.frameMsg(ts_model, .{ .width = 800, .height = 600, .timestampMs = 32, .intervalMs = 16 }) == null);
        try testing.expect(shim_core.frameMsg(shim_model, .{ .width = 800, .height = 600, .timestampMs = 32, .intervalMs = 16 }) == null);
    }

    // The key-fallback channel: a bare arm rides the header-only
    // envelope.
    {
        const ts_msg = ts_core.keyMsg(.{ .key = "space", .shift = false, .control = false, .alt = false, .super = false }) orelse return error.TestUnexpectedResult;
        const shim_msg = shim_core.keyMsg(.{ .key = "space", .shift = false, .control = false, .alt = false, .super = false }) orelse return error.TestUnexpectedResult;
        const next = try channelParityCycle(arena, ts_model, shim_model, ts_msg, shim_msg);
        ts_model = next.ts;
        shim_model = next.shim;
    }

    // The pinch channel: a flattened record payload (factor, source
    // identity) crosses the envelope and dispatches.
    {
        const ts_msg = ts_core.pinchMsg(.{ .windowId = 7, .label = "ts-markup-canvas", .phase = .change, .scale = 0.25, .x = 1, .y = 2 }) orelse return error.TestUnexpectedResult;
        const shim_msg = shim_core.pinchMsg(.{ .windowId = 7, .label = "ts-markup-canvas", .phase = .change, .scale = 0.25, .x = 1, .y = 2 }) orelse return error.TestUnexpectedResult;
        const next = try channelParityCycle(arena, ts_model, shim_model, ts_msg, shim_msg);
        ts_model = next.ts;
        shim_model = next.shim;
    }
}
