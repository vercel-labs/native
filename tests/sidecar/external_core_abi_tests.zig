//! ABI laws over a REAL compiled core: the build compiles the markup
//! fixture through the external core compiler and links the archive
//! into this binary beside a mirror generated from the archive's OWN
//! co-emitted sidecar (the boot identity fence pairs them), plus the
//! raw C ABI bindings. The suite drives one scripted message sequence
//! and pins the laws every compiled core must hold:
//!
//!   - boot: the identity fence passes, and a fixture whose init
//!     returns a bare model produces an EMPTY boot-command buffer;
//!   - snapshot fidelity: the committed-model snapshot decodes through
//!     the mirror's declared types and re-encodes to the same bytes,
//!     every cycle;
//!   - command bytes: the one command-producing arm (`stamp`) returns
//!     the `now` op's pinned wire bytes; every other cycle returns an
//!     empty command buffer;
//!   - collect invariant: a collect between dispatches leaves the
//!     observable snapshot byte-identical;
//!   - deterministic re-init: a second init lands the core back on the
//!     boot snapshot bytes;
//!   - channel envelopes ([produced u8][tag u8][payload…]): gating
//!     events return the two-byte nothing-produced envelope, produced
//!     arms decode and dispatch as full cycles, and the raw frame entry
//!     truncates fractional presentation widths before comparing;
//!   - integer classes: attested slots carry the compiler-provable
//!     extremes (+-(2^53 - 1)) through a real dispatch exactly.
//!
//! The e2e batteries (tests/ts-core) drive the same archives through
//! the full runtime; this suite is the ABI's own contract, held with
//! nothing above the C boundary.

const std = @import("std");
const corewire_rt = @import("corewire_rt");
const core_abi = @import("core_abi");

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

fn rawFrameMsg(width: f64, height: f64, timestamp_ms: f64, interval_ms: f64) []const u8 {
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    abi.frame_msg(width, height, timestamp_ms, interval_ms, &ptr, &len);
    return ptr[0..len];
}

/// Snapshot fidelity: the archive's raw snapshot bytes must equal the
/// canonical re-encoding of the mirror's decoded committed root — the
/// decoder and the archive's encoder agree on every byte.
fn expectSnapshotFidelity(model: *const shim_core.Model, arena: std.mem.Allocator) !void {
    try testing.expectEqualSlices(u8, rawSnapshot(), corewire_rt.encodeAlloc(shim_core.Model, model.*, arena));
}

/// The selection sample follows the sidecar's classes: a signed focus
/// keeps the negative-value coverage, an unsigned one exercises a
/// backward selection (anchor past focus) instead.
const selection_sample = blk: {
    const Selection = @FieldType(@FieldType(shim_core.Msg, "draft_edit"), "set_selection");
    if (carriesNegatives(@FieldType(Selection, "focus"))) {
        break :blk Selection{ .anchor = 1, .focus = -2 };
    }
    break :blk Selection{ .anchor = 3, .focus = 1 };
};

/// The scripted sequence: every dispatch entry class the fixture's
/// contract declares — bare arms, i64- and f64-classed numbers, bytes,
/// the text-input union (each payload family), and the three record
/// arms — plus the one command-producing arm (`stamp`).
const script = [_]shim_core.Msg{
    .add,
    .add,
    .{ .toggle = 2 },
    .{ .pick = 2.5 },
    .add,
    .cycle,
    .{ .banner_set = "parity" },
    .{ .draft_edit = .{ .insert_text = "hi" } },
    .{ .draft_edit = .delete_backward },
    .{ .draft_edit = .delete_to_start },
    .{ .draft_edit = .delete_to_line_start },
    .{ .draft_edit = .{ .move_caret = .{ .direction = .next_word, .extend = true } } },
    .{ .draft_edit = .{ .set_selection = selection_sample } },
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

/// The `now` command's wire bytes for the fixture's `stamp` cycle,
/// pinned: cmd format 3's `now` op carrying the `stamped` arm's
/// declaration-order wire tag. Captured from the compiled core and
/// reviewed against the wire format; a change here is a wire-format
/// or fixture change, never noise.
const now_cmd_bytes = [_]u8{ 2, 6 };

test "a compiled core holds the ABI laws over the scripted cycle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Boot. The mirror's initialModel runs the full boot fence against
    // the archive (identity getters, sink, init); the fixture's
    // contract declares no boot command, so the archive's boot_cmd
    // buffer must be empty.
    var shim_model = shim_core.commitModelRoot(shim_core.initialModel());
    {
        var boot_ptr: [*]const u8 = undefined;
        var boot_len: usize = 0;
        abi.boot_cmd(&boot_ptr, &boot_len);
        try testing.expectEqualSlices(u8, "", boot_ptr[0..boot_len]);
    }
    try expectSnapshotFidelity(shim_model, arena);
    // The boot snapshot bytes, kept for the deterministic re-init pin.
    const boot_snapshot = try arena.dupe(u8, rawSnapshot());
    shim_core.rt.frameReset();

    for (script, 0..) |msg, step| {
        // One cycle, the host adapter's ordering: update, commit,
        // consume the command bytes, then frame reset.
        const shim_out = shim_core.update(shim_model, msg);
        shim_model = shim_core.commitModelRoot(shim_out.model);

        // The command surface: `stamp` is the fixture's one
        // command-producing arm; every other cycle returns nothing.
        if (msg == .stamp) {
            testing.expectEqualSlices(u8, &now_cmd_bytes, shim_out.cmd) catch |err| {
                std.debug.print("stamp command bytes at step {d}: {x}\n", .{ step, shim_out.cmd });
                return err;
            };
        } else {
            testing.expectEqualSlices(u8, "", shim_out.cmd) catch |err| {
                std.debug.print("unexpected command bytes at script step {d} ({s}): {x}\n", .{ step, @tagName(msg), shim_out.cmd });
                return err;
            };
        }
        expectSnapshotFidelity(shim_model, arena) catch |err| {
            std.debug.print("snapshot fidelity diverges at script step {d} ({s})\n", .{ step, @tagName(msg) });
            return err;
        };

        // Between dispatches, a collect must leave the observable model
        // untouched (the ABI's collect invariant), and the fixture's
        // contract declares no subscriptions, so the buffer stays
        // empty.
        if (step % 3 == 2) {
            const reference = try arena.dupe(u8, rawSnapshot());
            abi.collect();
            testing.expectEqualSlices(u8, reference, rawSnapshot()) catch |err| {
                std.debug.print("collect changed the observable snapshot at script step {d} ({s})\n", .{ step, @tagName(msg) });
                return err;
            };
        }
        try testing.expectEqualSlices(u8, "", rawSubscriptions());

        shim_core.rt.frameReset();
    }

    // Deterministic re-init: a second boot lands the core back on the
    // boot bytes.
    shim_core.rt.resetAll();
    shim_model = shim_core.commitModelRoot(shim_core.initialModel());
    try testing.expectEqualSlices(u8, boot_snapshot, rawSnapshot());
    shim_core.rt.frameReset();
}

/// One dispatch cycle over one message, holding snapshot fidelity.
fn singleCycle(
    arena: std.mem.Allocator,
    shim_model: *const shim_core.Model,
    msg: shim_core.Msg,
) !*const shim_core.Model {
    const shim_out = shim_core.update(shim_model, msg);
    const next = shim_core.commitModelRoot(shim_out.model);
    try expectSnapshotFidelity(next, arena);
    shim_core.rt.frameReset();
    return next;
}

test "integer-classed slots cross the compiler-provable extremes exactly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A fresh boot (init is the deterministic re-init seam, so this
    // test stands alone). The archive's sidecar attests its integer
    // classes; the classed arms carry the +-(2^53 - 1) extremes through
    // a real dispatch, the snapshot bytes round-trip through the
    // mirror's decoder, and the decoded slots hold the exact integers.
    shim_core.rt.resetAll();
    var shim_model = shim_core.commitModelRoot(shim_core.initialModel());
    shim_core.rt.frameReset();

    // The extremes follow each slot's class in the sidecar: a signed
    // slot also crosses the negative extreme; a u64-attested one stays
    // within its unsigned range. Every crossing value sits within
    // +-(2^53 - 1), so each class carries it exactly.
    const max_exact = 9007199254740991; // 2^53 - 1
    const boundary_script = comptime blk: {
        var msgs: []const shim_core.Msg = &.{
            .{ .canvas_resized = max_exact },
            .{ .toggle = max_exact },
        };
        if (carriesNegatives(@FieldType(shim_core.Msg, "toggle"))) {
            msgs = msgs ++ [_]shim_core.Msg{.{ .toggle = -max_exact }};
        }
        if (carriesNegatives(@FieldType(shim_core.Msg, "canvas_resized"))) {
            msgs = msgs ++ [_]shim_core.Msg{.{ .canvas_resized = -max_exact }};
        }
        msgs = msgs ++ [_]shim_core.Msg{.{ .canvas_resized = 0 }};
        break :blk msgs;
    };
    inline for (boundary_script, 0..) |msg, step| {
        shim_model = singleCycle(arena, shim_model, msg) catch |err| {
            std.debug.print("integer boundary fidelity diverges at step {d} ({s})\n", .{ step, @tagName(msg) });
            return err;
        };
        // The mirror decoded the committed snapshot: its numeric slot
        // holds the exact crossing value (compared class-agnostically —
        // the arm and the field each follow their own class, and every
        // crossing value is f64-exact).
        switch (msg) {
            .canvas_resized => |value| try testing.expectEqual(exactValue(value), exactValue(shim_model.canvasWidth)),
            else => {},
        }
    }
}

/// Whether a mirror slot's class carries negative values: signed
/// integers and f64 do; the unsigned class does not.
fn carriesNegatives(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |info| info.signedness == .signed,
        .float => true,
        else => @compileError("not a numeric mirror slot: " ++ @typeName(T)),
    };
}

/// A class-agnostic exact comparison value: every crossing this suite
/// drives sits within +-(2^53 - 1), where f64 carries integers exactly.
fn exactValue(value: anytype) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int => @floatFromInt(value),
        .float => value,
        else => @compileError("not a numeric mirror slot: " ++ @typeName(@TypeOf(value))),
    };
}

test "channel entries hold the bytes-envelope laws" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A fresh boot (init is the deterministic re-init seam, so this
    // test stands alone).
    shim_core.rt.resetAll();
    var shim_model = shim_core.commitModelRoot(shim_core.initialModel());
    shim_core.rt.frameReset();

    // Gating: a chorded key, an unchanged frame, and a begin pinch
    // produce nothing (the archive's entry returns the two-byte
    // nothing-produced envelope, which the mirror gates to null).
    try testing.expect(shim_core.keyMsg(.{ .key = "space", .shift = false, .control = true, .alt = false, .super = false }) == null);
    try testing.expect(shim_core.frameMsg(shim_model, .{ .width = 0, .height = 600, .timestampMs = 16, .intervalMs = 16 }) == null);
    try testing.expect(shim_core.pinchMsg(.{ .windowId = 7, .label = "ts-markup-canvas", .phase = .begin, .scale = 0, .x = 1, .y = 2 }) == null);
    const ignored_paths = [_][]const u8{"/tmp/ignored.txt"};
    try testing.expect(shim_core.dropMsg(.{ .windowId = 1, .viewLabel = "ts-markup-canvas", .point = null, .paths = &ignored_paths }) == null);

    // The presented-frame channel produces the resize at boot width,
    // and the dispatched cycle updates the model so the same frame then
    // gates (the idle law, proven across the round trip).
    {
        const msg = shim_core.frameMsg(shim_model, .{ .width = 800, .height = 600, .timestampMs = 16, .intervalMs = 16 }) orelse return error.TestUnexpectedResult;
        shim_model = try singleCycle(arena, shim_model, msg);
        try testing.expect(shim_core.frameMsg(shim_model, .{ .width = 800, .height = 600, .timestampMs = 32, .intervalMs = 16 }) == null);
        // The raw archive entry receives f64 logical points before the
        // generated mirror narrows its classed width. Compare after
        // truncation so a fractional presentation at the committed
        // width does not keep the channel alive.
        try testing.expectEqualSlices(u8, &.{ 0, 0 }, rawFrameMsg(800.75, 600, 48, 16));
    }

    // The key-fallback channel: a bare arm rides the header-only
    // envelope, and its cycle dispatches.
    {
        const msg = shim_core.keyMsg(.{ .key = "space", .shift = false, .control = false, .alt = false, .super = false }) orelse return error.TestUnexpectedResult;
        try testing.expect(msg == .cycle);
        shim_model = try singleCycle(arena, shim_model, msg);
    }

    // The pinch channel: a flattened record payload (factor, source
    // identity) crosses the envelope and dispatches.
    {
        const msg = shim_core.pinchMsg(.{ .windowId = 7, .label = "ts-markup-canvas", .phase = .change, .scale = 0.25, .x = 1, .y = 2 }) orelse return error.TestUnexpectedResult;
        try testing.expect(msg == .zoomed);
        shim_model = try singleCycle(arena, shim_model, msg);
    }

    // The drop channel: the nested optional point and byte-text path
    // sequence cross the one canonical event buffer into the core.
    {
        const paths = [_][]const u8{ "/tmp/first.txt", "/tmp/second.txt" };
        const msg = shim_core.dropMsg(.{
            .windowId = 1,
            .viewLabel = "ts-markup-canvas",
            .point = .{ .x = 12.5, .y = 24.25 },
            .paths = &paths,
        }) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("/tmp/first.txt", msg.banner_set);
        shim_model = try singleCycle(arena, shim_model, msg);
        try testing.expectEqualStrings("/tmp/first.txt", shim_model.banner);
    }
}
