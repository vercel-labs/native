//! Compiled TypeScript projection over the native structural decoder.
const std = @import("std");
const sidecar_mod = @import("sidecar.zig");
const Sidecar = sidecar_mod.Sidecar;
pub const Error = error{ Refused, OutOfMemory };

pub fn emit(arena: std.mem.Allocator, sidecar: Sidecar, diags: *sidecar_mod.Diagnostics) Error![]const u8 {
    return @import("core_emission.zig").emit(arena, sidecar, .mirror, diags);
}

const testing = std.testing;

fn emitFromJson(arena: std.mem.Allocator, json: []const u8) ![]const u8 {
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = sidecar_mod.read(arena, json, &diags) catch |err| {
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        diags.write("sidecar", &writer) catch {};
        std.debug.print("{s}", .{writer.buffered()});
        return err;
    };
    return emit(arena, parsed, &diags) catch |err| {
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        diags.write("sidecar", &writer) catch {};
        std.debug.print("{s}", .{writer.buffered()});
        return err;
    };
}

test "emission is deterministic and carries the mirror surface" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try emitFromJson(arena, sidecar_mod.minimal_valid_json);
    const second = try emitFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expectEqualStrings(first, second);
    try testing.expect(std.mem.indexOf(u8, first, "pub const Model = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "count: i64,") != null);
    try testing.expect(std.mem.indexOf(u8, first, "pub const Msg = union(enum) {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "label_set: []const u8,") != null);
    try testing.expect(std.mem.indexOf(u8, first, "abi.dispatch_void(0,") != null);
    try testing.expect(std.mem.indexOf(u8, first, "abi.dispatch_bytes(1,") != null);
    // A bare-model init emits the pointer-returning shape.
    try testing.expect(std.mem.indexOf(u8, first, "pub fn initialModel() *const Model {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "pub const UpdateResult = struct { model: *const Model, cmd: rt.Cmd };") != null);

    const command_init_source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"init_returns_cmd\": false",
        "\"init_returns_cmd\": true",
    );
    const command_init = try emitFromJson(arena, command_init_source);
    try testing.expect(std.mem.indexOf(u8, command_init, "pub fn bootCommand() rt.Cmd {") != null);
    try testing.expect(std.mem.indexOf(u8, command_init, ".cmd = bootCommand()") != null);
}

test "u64-attested slots generate the unsigned twin; i64 and f64 slots are untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Every slot-path form the grammar can attest, classes mixed: the
    // attested class decides the mirror's decode width per slot, and
    // nothing leaks across slots.
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"count\", \"type\": {\"kind\": \"i64\"}}",
        "{\"name\": \"count\", \"type\": {\"kind\": \"i64\"}},\n        {\"name\": \"delta\", \"type\": {\"kind\": \"i64\"}},\n        {\"name\": \"ratio\", \"type\": {\"kind\": \"f64\"}}",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"tick\", \"payload\": {\"kind\": \"number\", \"class\": \"i64\"}},\n      {\"name\": \"stepped\", \"payload\": {\"kind\": \"number\", \"class\": \"i64\"}},\n      {\"name\": \"fetched\", \"payload\": {\"kind\": \"number_bytes\", \"number_field\": \"status\", \"number_class\": \"i64\", \"bytes_field\": \"body\"}}",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"peak\", \"params\": [], \"returns\": {\"kind\": \"i64\"}, \"arena\": false}]",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        \\{"slot": "Model.count", "class": "u64"},
        \\    {"slot": "Model.delta", "class": "i64"},
        \\    {"slot": "Msg.tick", "class": "u64"},
        \\    {"slot": "Msg.stepped", "class": "i64"},
        \\    {"slot": "Msg.fetched.status", "class": "u64"},
        \\    {"slot": "helpers.peak.return", "class": "u64"}
        ,
    );
    const generated = try emitFromJson(arena, source);
    // Mirror spellings follow the attestation, slot by slot.
    try testing.expect(std.mem.indexOf(u8, generated, "count: u64,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "delta: i64,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "ratio: f64,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "tick: u64,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "stepped: i64,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "fetched: struct { status: u64, body: []const u8 },") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub fn peak(self: *const Model) u64 {") != null);
    // Dispatch narrows through the matching exactness guard.
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_number(0, shim_rt.exactF64Unsigned(payload), &cmd_ptr, &cmd_len)") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_number(1, shim_rt.exactF64(payload), &cmd_ptr, &cmd_len)") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_number_bytes(2, shim_rt.exactF64Unsigned(payload.status), payload.body.ptr, payload.body.len, &cmd_ptr, &cmd_len)") != null);
    // The generated module stays valid Zig.
    const source_z = try arena.dupeZ(u8, generated);
    const tree = try std.zig.Ast.parse(arena, source_z, .zig);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "u64 attestations on host-supplied signed slots refuse at check time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A scroll-state record with a u64-attested axis: scroll translation
    // supplies negative offsets and velocities, which the unsigned class
    // cannot carry — refused before any wiring generates.
    const scroll_struct =
        \\      {"name": "Scroll", "fields": [
        \\        {"name": "offsetX", "type": {"kind": "f64"}},
        \\        {"name": "offsetY", "type": {"kind": "i64"}},
        \\        {"name": "velocityX", "type": {"kind": "f64"}},
        \\        {"name": "velocityY", "type": {"kind": "f64"}},
        \\        {"name": "viewportExtentX", "type": {"kind": "f64"}},
        \\        {"name": "viewportExtentY", "type": {"kind": "f64"}},
        \\        {"name": "contentExtentX", "type": {"kind": "f64"}},
        \\        {"name": "contentExtentY", "type": {"kind": "f64"}}
        \\      ]},
    ;
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"structs\": [\n",
        try std.fmt.allocPrint(arena, "\"structs\": [\n{s}\n", .{scroll_struct}),
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}},\n      {\"name\": \"scrolled\", \"payload\": {\"kind\": \"record\", \"name\": \"Scroll\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Scroll.offsetY\", \"class\": \"u64\"}");
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "scroll-state axis") != null) found = true;
    }
    try testing.expect(found);
    // The same record i64-attested generates: only the unsigned class
    // is incoherent with the host's signed values.
    const signed = try std.mem.replaceOwned(u8, arena, source, "{\"slot\": \"Scroll.offsetY\", \"class\": \"u64\"}", "{\"slot\": \"Scroll.offsetY\", \"class\": \"i64\"}");
    const generated = try emitFromJson(arena, signed);
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_scroll_state(1,") != null);

    // Extents stay attestable: the host only ever supplies viewport and
    // content sizes non-negative, so the unsigned class carries them.
    var extent_source = try std.mem.replaceOwned(u8, arena, source, "{\"name\": \"offsetY\", \"type\": {\"kind\": \"i64\"}}", "{\"name\": \"offsetY\", \"type\": {\"kind\": \"f64\"}}");
    extent_source = try std.mem.replaceOwned(u8, arena, extent_source, "{\"name\": \"viewportExtentY\", \"type\": {\"kind\": \"f64\"}}", "{\"name\": \"viewportExtentY\", \"type\": {\"kind\": \"i64\"}}");
    extent_source = try std.mem.replaceOwned(u8, arena, extent_source, "{\"slot\": \"Scroll.offsetY\", \"class\": \"u64\"}", "{\"slot\": \"Scroll.viewportExtentY\", \"class\": \"u64\"}");
    const extent_generated = try emitFromJson(arena, extent_source);
    try testing.expect(std.mem.indexOf(u8, extent_generated, "shim_rt.exactF64Unsigned(payload.viewportExtentY)") != null);

    // A scroll-shaped record no message arm routes is not scroll state
    // to the host: a model-only metrics record keeps its unsigned
    // attestation even on an axis-named field.
    var model_only = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}},\n      {\"name\": \"scrolled\", \"payload\": {\"kind\": \"record\", \"name\": \"Scroll\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
    );
    model_only = try std.mem.replaceOwned(
        u8,
        arena,
        model_only,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}, {\"name\": \"metrics\", \"type\": {\"kind\": \"value\", \"name\": \"Scroll\"}}",
    );
    const model_only_generated = try emitFromJson(arena, model_only);
    try testing.expect(std.mem.indexOf(u8, model_only_generated, "offsetY: u64,") != null);
}

test "a u64 attestation on chrome geometry refuses at check time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A wired chrome arm whose buttons record attests x as u64:
    // embedders report signed content coordinates, which the unsigned
    // class cannot carry.
    const source =
        \\{
        \\  "format": 1, "wire_version": 7, "abi_version": 2,
        \\  "compiler_version": "0.0.1", "entry": "src/core.ts",
        \\  "source_hash": "00000000c0ffee00", "build_id": "00000000b01dface", "model_fingerprint": "00000000a11ce001",
        \\  "types": {
        \\    "structs": [
        \\      {"name": "Model", "fields": [{"name": "chromeTop", "type": {"kind": "f64"}}]},
        \\      {"name": "Insets", "fields": [
        \\        {"name": "top", "type": {"kind": "f64"}}, {"name": "right", "type": {"kind": "f64"}},
        \\        {"name": "bottom", "type": {"kind": "f64"}}, {"name": "left", "type": {"kind": "f64"}}
        \\      ]},
        \\      {"name": "Buttons", "fields": [
        \\        {"name": "x", "type": {"kind": "i64"}}, {"name": "y", "type": {"kind": "f64"}},
        \\        {"name": "width", "type": {"kind": "f64"}}, {"name": "height", "type": {"kind": "f64"}}
        \\      ]},
        \\      {"name": "Msg_chrome_changed", "fields": [
        \\        {"name": "insets", "type": {"kind": "value", "name": "Insets"}},
        \\        {"name": "buttons", "type": {"kind": "value", "name": "Buttons"}},
        \\        {"name": "tabsProjected", "type": {"kind": "bool"}}
        \\      ]}
        \\    ],
        \\    "enums": [], "unions": []
        \\  },
        \\  "model": "Model", "model_helpers": [], "model_unbound": [],
        \\  "msg": {"name": "Msg", "arms": [
        \\    {"name": "chrome_changed", "payload": {"kind": "record", "name": "Msg_chrome_changed"}}
        \\  ], "unbound": []},
        \\  "init_returns_cmd": false, "update_returns_cmd": true, "has_subscriptions": false, "has_migrate": false,
        \\  "channels": {"command_msg": false, "frame_msg": false, "key_msg": false, "pinch_msg": false, "drop_msg": false,
        \\    "appearance_msg": null, "chrome_msg": "chrome_changed", "env_msgs": []},
        \\  "abi": {"prefix": "nsc_core_", "exports": ["abi_version", "build_id", "set_panic_sink", "init",
        \\    "collect", "frame_reset", "boot_cmd", "dispatch_void", "dispatch_bytes", "dispatch_number",
        \\    "dispatch_number_bytes", "dispatch_bool", "dispatch_enum", "dispatch_record",
        \\    "dispatch_text_input", "dispatch_scroll_state", "subscriptions", "model_snapshot",
        \\    "persist_snapshot", "restore_model", "migrate_model", "helper_call"], "snapshot_format": 1},
        \\  "integer_slots": [{"slot": "Buttons.x", "class": "u64"}],
        \\  "deterministic": true, "async_free": true
        \\}
    ;
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "window-control cluster's position") != null) found = true;
    }
    try testing.expect(found);

    // Insets and cluster sizes are non-negative overlay extents: the
    // unsigned class carries them.
    var arena_state2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state2.deinit();
    const arena2 = arena_state2.allocator();
    var extents = try std.mem.replaceOwned(u8, arena2, source, "{\"name\": \"x\", \"type\": {\"kind\": \"i64\"}}", "{\"name\": \"x\", \"type\": {\"kind\": \"f64\"}}");
    extents = try std.mem.replaceOwned(u8, arena2, extents, "{\"name\": \"top\", \"type\": {\"kind\": \"f64\"}}", "{\"name\": \"top\", \"type\": {\"kind\": \"i64\"}}");
    extents = try std.mem.replaceOwned(u8, arena2, extents, "{\"slot\": \"Buttons.x\", \"class\": \"u64\"}", "{\"slot\": \"Insets.top\", \"class\": \"u64\"}");
    const generated = try emitFromJson(arena2, extents);
    try testing.expect(std.mem.indexOf(u8, generated, "top: u64,") != null);
}

test "u64 attestations on selection bounds are accepted (the host supplies unsigned offsets)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The full text-input vocabulary with a u64-attested selection
    // anchor: the engine's selection bounds are unsigned offsets (a
    // backward selection is anchor > focus, never a negative index), so
    // the unsigned class carries every host-supplied value.
    const records =
        \\      {"name": "Move", "fields": [
        \\        {"name": "direction", "type": {"kind": "enum", "name": "Dir"}},
        \\        {"name": "extend", "type": {"kind": "bool"}}
        \\      ]},
        \\      {"name": "Sel", "fields": [
        \\        {"name": "anchor", "type": {"kind": "i64"}},
        \\        {"name": "focus", "type": {"kind": "i64"}}
        \\      ]},
        \\      {"name": "Comp", "fields": [
        \\        {"name": "text", "type": {"kind": "bytes"}},
        \\        {"name": "cursor", "type": {"kind": "optional", "inner": {"kind": "i64"}}}
        \\      ]},
    ;
    const union_entry =
        \\"unions": [{"name": "Edit", "arms": [
        \\      {"name": "insert_text", "payload": {"kind": "bytes"}},
        \\      {"name": "delete_backward", "payload": {"kind": "void"}},
        \\      {"name": "delete_forward", "payload": {"kind": "void"}},
        \\      {"name": "delete_word_backward", "payload": {"kind": "void"}},
        \\      {"name": "delete_word_forward", "payload": {"kind": "void"}},
        \\      {"name": "delete_to_start", "payload": {"kind": "void"}},
        \\      {"name": "delete_to_line_start", "payload": {"kind": "void"}},
        \\      {"name": "clear", "payload": {"kind": "void"}},
        \\      {"name": "move_caret", "payload": {"kind": "value", "name": "Move"}},
        \\      {"name": "set_selection", "payload": {"kind": "value", "name": "Sel"}},
        \\      {"name": "set_composition", "payload": {"kind": "value", "name": "Comp"}},
        \\      {"name": "commit_composition", "payload": {"kind": "void"}},
        \\      {"name": "cancel_composition", "payload": {"kind": "void"}}
        \\    ]}]
    ;
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [\n", try std.fmt.allocPrint(arena, "\"structs\": [\n{s}\n", .{records}));
    source = try std.mem.replaceOwned(u8, arena, source, "\"enums\": []", "\"enums\": [{\"name\": \"Dir\", \"members\": [\"previous\", \"next\", \"previous_word\", \"next_word\", \"start\", \"end\"]}]");
    source = try std.mem.replaceOwned(u8, arena, source, "\"unions\": []", union_entry);
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"edited\", \"payload\": {\"kind\": \"union\", \"name\": \"Edit\"}}",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Sel.anchor\", \"class\": \"u64\"}, {\"slot\": \"Sel.focus\", \"class\": \"u64\"}, {\"slot\": \"Comp.cursor\", \"class\": \"u64\"}",
    );
    const generated = try emitFromJson(arena, source);
    // The mirror spells the attested classes and the union still routes
    // through the text-input entry (recognition is spelling-level).
    try testing.expect(std.mem.indexOf(u8, generated, "anchor: u64,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "focus: u64,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "cursor: ?u64,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_text_input(0,") != null);
}

test "the empty integer_slots list decodes nothing differently" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The f64-only sequencing: every numeric slot spelled f64, the
    // empty list attested — the mirror carries f64 slots and no
    // integer narrowing anywhere.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "{\"name\": \"count\", \"type\": {\"kind\": \"i64\"}}", "{\"name\": \"count\", \"type\": {\"kind\": \"f64\"}}");
    source = try std.mem.replaceOwned(u8, arena, source, "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}", "{\"name\": \"picked\", \"payload\": {\"kind\": \"number\", \"class\": \"f64\"}}");
    source = try std.mem.replaceOwned(u8, arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "");
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "count: f64,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "picked: f64,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_number(0, payload, &cmd_ptr, &cmd_len)") != null);
    // No integer narrowing and no integer-spelled mirror slot anywhere
    // (the identity constants' own u64 plumbing is not a mirror slot).
    try testing.expect(std.mem.indexOf(u8, generated, "exactF64") == null);
    try testing.expect(std.mem.indexOf(u8, generated, ": i64,") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "count: u64,") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "picked: u64,") == null);
}

test "the emitted shim parses as Zig" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try emitFromJson(arena, sidecar_mod.minimal_valid_json);
    const source_z = try arena.dupeZ(u8, source);
    const tree = try std.zig.Ast.parse(arena, source_z, .zig);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "a type name colliding with a shim declaration refuses with a teaching" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The model root renamed to "rt": layout-legal, but the generated
    // module must also declare its kernel block under that name.
    const renamed = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"Model\"", "\"rt\"");
    const with_slot = try std.mem.replaceOwned(u8, arena, renamed, "\"slot\": \"Model.count\"", "\"slot\": \"rt.count\"");
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, with_slot, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "collides with a declaration") != null) found = true;
    }
    try testing.expect(found);
}

test "a shared authored type spelling like a synthesized name stays a top-level declaration" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // "Model_user" is referenced from BOTH Model.user (where the
    // synthesized pattern matches) and Model.backup: inlining it at the
    // first site would leave the second dangling.
    const source =
        \\{
        \\  "format": 1, "wire_version": 7, "abi_version": 2,
        \\  "compiler_version": "0.0.1", "entry": "src/core.ts",
        \\  "source_hash": "00000000c0ffee00", "build_id": "00000000b01dface", "model_fingerprint": "00000000a11ce001",
        \\  "types": {
        \\    "structs": [
        \\      {"name": "Model_user", "fields": [{"name": "id", "type": {"kind": "f64"}}]},
        \\      {"name": "Model", "fields": [
        \\        {"name": "user", "type": {"kind": "value", "name": "Model_user"}},
        \\        {"name": "backup", "type": {"kind": "value", "name": "Model_user"}}
        \\      ]}
        \\    ],
        \\    "enums": [], "unions": []
        \\  },
        \\  "model": "Model", "model_helpers": [], "model_unbound": [],
        \\  "msg": {"name": "Msg", "arms": [{"name": "bump", "payload": {"kind": "void"}}], "unbound": []},
        \\  "init_returns_cmd": false, "update_returns_cmd": true, "has_subscriptions": false, "has_migrate": false,
        \\  "channels": {"command_msg": false, "frame_msg": false, "key_msg": false, "pinch_msg": false, "drop_msg": false,
        \\    "appearance_msg": null, "chrome_msg": null, "env_msgs": []},
        \\  "abi": {"prefix": "nsc_core_", "exports": ["abi_version", "build_id", "set_panic_sink", "init",
        \\    "collect", "frame_reset", "boot_cmd", "dispatch_void", "dispatch_bytes", "dispatch_number",
        \\    "dispatch_number_bytes", "dispatch_bool", "dispatch_enum", "dispatch_record",
        \\    "dispatch_text_input", "dispatch_scroll_state", "subscriptions", "model_snapshot",
        \\    "persist_snapshot", "restore_model", "migrate_model", "helper_call"], "snapshot_format": 1},
        \\  "integer_slots": [], "deterministic": true, "async_free": true
        \\}
    ;
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const Model_user = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "user: Model_user,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "backup: Model_user,") != null);
}

test "exotic strings in names and env entries emit as valid Zig" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"env_msgs\": []",
        "\"env_msgs\": [{\"env\": \"APP\\\"MODE\\\\X\", \"msg\": \"label_set\"}]",
    );
    const parsed = try sidecar_mod.read(arena, source, &diags);
    const generated = try emit(arena, parsed, &diags);
    const source_z = try arena.dupeZ(u8, generated);
    const tree = try std.zig.Ast.parse(arena, source_z, .zig);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
    try testing.expect(std.mem.indexOf(u8, generated, "APP\\\"MODE\\\\X") != null);
}

test "channel glue speaks the sidecar's message union name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Rename the union to "Event" and wire the key channel.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"name\": \"Msg\"", "\"name\": \"Event\"");
    source = try std.mem.replaceOwned(u8, arena, source, "\"key_msg\": false", "\"key_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"helper_call\"]", "\"helper_call\", \"key_msg\"]");
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const Event = union(enum) {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub fn keyMsg(key: KeyEvent) ?Event {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "fn msgFromEnvelope(envelope: []const u8) ?Event {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "@FieldType(Event, \"label_set\")") != null);
    // The channel entry returns the bytes envelope on the ordinary
    // out-pointer pair; the wrapper hands the whole buffer to the
    // unpacker (no status return, no out-record). The out state is
    // DEFINED before the call: an entry that returns without writing
    // yields the zero-length envelope, which the envelope reader
    // refuses as short.
    try testing.expect(std.mem.indexOf(u8, generated, "var out_ptr: [*]const u8 = &shim_rt.channel_out_guard;\n    var out_len: usize = 0;\n    abi.key_msg(key.key.ptr, key.key.len, @intFromBool(key.shift), @intFromBool(key.control), @intFromBool(key.alt), @intFromBool(key.super), &out_ptr, &out_len);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "return msgFromEnvelope(shim_rt.channelEnvelopeBytes(out_ptr, out_len));") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "shim_rt.channelEnvelope(envelope)") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (!header.produced) return null;") != null);
    const source_z = try arena.dupeZ(u8, generated);
    const tree = try std.zig.Ast.parse(arena, source_z, .zig);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "optional glue names are reserved only when the glue is emitted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // No helpers and no function channels: a reachable type named
    // "callHelper" collides with nothing the shim declares.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"callHelper\", \"members\": [\"on\", \"off\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"callHelper\"}}",
    );
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const callHelper = enum(u8) {") != null);
}

test "UpdateResult reserves only when the cmd-returning update emits it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"update_returns_cmd\": true", "\"update_returns_cmd\": false");
    source = try std.mem.replaceOwned(u8, arena, source, "\"enums\": []", "\"enums\": [{\"name\": \"UpdateResult\", \"members\": [\"a\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"UpdateResult\"}}",
    );
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const UpdateResult = enum(u8) {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub fn update(model: *const Model, msg: Msg) *const Model {") != null);
}

test "model-only update does not pointlessly discard command out variables" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"update_returns_cmd\": true", "\"update_returns_cmd\": false");
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "pub fn update(model: *const Model, msg: Msg) *const Model {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_void(0, &cmd_ptr, &cmd_len)") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "_ = cmd_ptr;") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "_ = cmd_len;") == null);
}

test "a node-stored record as a message arm payload refuses; value-stored passes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Item lives in the model graph AND doubles as an arm payload: the
    // compiled core stores that arm by reference, which the record
    // family cannot say — mirroring by value would skew the layout.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Item\", \"fields\": [{\"name\": \"id\", \"type\": {\"kind\": \"f64\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"node\", \"name\": \"Item\"}}",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"picked\", \"payload\": {\"kind\": \"record\", \"name\": \"Item\"}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "stored by reference in the model graph") != null) found = true;
    }
    try testing.expect(found);

    // The value-stored counterpart is exactly how value-promoted model
    // records (a text-input union's caret and selection payloads) reach
    // arms in the emitted lane — it must generate.
    var value_source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Sel\", \"fields\": [{\"name\": \"anchor\", \"type\": {\"kind\": \"f64\"}}]},");
    value_source = try std.mem.replaceOwned(
        u8,
        arena,
        value_source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"value\", \"name\": \"Sel\"}}",
    );
    value_source = try std.mem.replaceOwned(
        u8,
        arena,
        value_source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"picked\", \"payload\": {\"kind\": \"record\", \"name\": \"Sel\"}}",
    );
    const value_generated = try emitFromJson(arena, value_source);
    try testing.expect(std.mem.indexOf(u8, value_generated, "picked: Sel,") != null);
}

test "a type named view_unbound refuses (the nested tuple would shadow it)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"view_unbound\", \"members\": [\"a\", \"b\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"view_unbound\"}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
}

test "a type named after the tag-table capture refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The comptime consistency block captures |field, tag_name|; a
    // module-level type under either spelling would be shadowed.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"field\", \"members\": [\"a\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"field\"}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
}

test "a helper taking a generated glue name refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Methods shadow file-scope declarations inside the model struct: a
    // helper named callHelper would capture the forwarders' own calls.
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"callHelper\", \"params\": [], \"returns\": {\"kind\": \"bool\"}, \"arena\": false}]",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "shadow file-scope names") != null) found = true;
    }
    try testing.expect(found);
}

test "a helper named view_unbound refuses with a teaching" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"view_unbound\", \"params\": [], \"returns\": {\"kind\": \"bool\"}, \"arena\": false}]",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "opt-out tuple") != null) found = true;
    }
    try testing.expect(found);
}

test "a text-input-named union without the payload shapes rides the record entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Thirteen right names, wrong insert_text payload (void): the markup
    // predicate would not bind this as text input, so dispatch must
    // not route it to the text_input entry either.
    var arms: std.ArrayListUnmanaged(u8) = .empty;
    const tags = [_][]const u8{
        "insert_text",         "delete_backward", "delete_forward",       "delete_word_backward",
        "delete_word_forward", "delete_to_start", "delete_to_line_start", "clear",
        "move_caret",          "set_selection",   "set_composition",      "commit_composition",
        "cancel_composition",
    };
    for (tags, 0..) |tag, index| {
        if (index > 0) try arms.appendSlice(arena, ", ");
        const one = try std.fmt.allocPrint(arena, "{{\"name\": \"{s}\", \"payload\": {{\"kind\": \"void\"}}}}", .{tag});
        try arms.appendSlice(arena, one);
    }
    const union_entry = try std.fmt.allocPrint(arena, "\"unions\": [{{\"name\": \"NotTextInput\", \"arms\": [{s}]}}]", .{arms.items});
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"unions\": []", union_entry);
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"union\", \"name\": \"NotTextInput\"}}",
    );
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_record(0,") != null);
    // No arm may route through the text-input entry (the attestation
    // block still references the symbol; only dispatch matters here).
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_text_input(0,") == null);
}

test "the two-axis scroll-state record dispatches as direct scalars" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The eight per-axis fields in the TS spelling (the emitted-core
    // mirror keeps the author's names), declaration order: the shape
    // the markup predicate binds as `on-scroll`, so dispatch must ride
    // the dedicated scalar entry, never the encoded record entry.
    const scroll_struct =
        \\      {"name": "Scroll", "fields": [
        \\        {"name": "offsetX", "type": {"kind": "f64"}},
        \\        {"name": "offsetY", "type": {"kind": "f64"}},
        \\        {"name": "velocityX", "type": {"kind": "f64"}},
        \\        {"name": "velocityY", "type": {"kind": "f64"}},
        \\        {"name": "viewportExtentX", "type": {"kind": "f64"}},
        \\        {"name": "viewportExtentY", "type": {"kind": "f64"}},
        \\        {"name": "contentExtentX", "type": {"kind": "f64"}},
        \\        {"name": "contentExtentY", "type": {"kind": "f64"}}
        \\      ]},
    ;
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"structs\": [\n",
        try std.fmt.allocPrint(arena, "\"structs\": [\n{s}\n", .{scroll_struct}),
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}},\n      {\"name\": \"scrolled\", \"payload\": {\"kind\": \"record\", \"name\": \"Scroll\"}}",
    );
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(
        u8,
        generated,
        "abi.dispatch_scroll_state(1, payload.offsetX, payload.offsetY, payload.velocityX, payload.velocityY, payload.viewportExtentX, payload.viewportExtentY, payload.contentExtentX, payload.contentExtentY, &cmd_ptr, &cmd_len)",
    ) != null);
}

test "the retired one-axis scroll quartet rides the record entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The pre-two-axis shape `{offset, velocity, viewportExtent,
    // contentExtent}` is an ordinary record now — the markup engines
    // refuse to bind `on-scroll` to it (with a teaching that names the
    // per-axis fields), so dispatch must not claim the scalar entry.
    const legacy_struct =
        \\      {"name": "Scroll", "fields": [
        \\        {"name": "offset", "type": {"kind": "f64"}},
        \\        {"name": "velocity", "type": {"kind": "f64"}},
        \\        {"name": "viewportExtent", "type": {"kind": "f64"}},
        \\        {"name": "contentExtent", "type": {"kind": "f64"}}
        \\      ]},
    ;
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"structs\": [\n",
        try std.fmt.allocPrint(arena, "\"structs\": [\n{s}\n", .{legacy_struct}),
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}},\n      {\"name\": \"scrolled\", \"payload\": {\"kind\": \"record\", \"name\": \"Scroll\"}}",
    );
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_record(1,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_scroll_state(1,") == null);
}

test "boot references every attested export so the link proves the set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const generated = try emitFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expect(std.mem.indexOf(u8, generated, "fn referenceAttestedExports() void {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "std.mem.doNotOptimizeAway(abi.collect);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "std.mem.doNotOptimizeAway(abi.abi_version_fn);") != null);
    // Unwired channel entries are NOT attested and must not be
    // referenced (their absence in the object is the valid state).
    try testing.expect(std.mem.indexOf(u8, generated, "doNotOptimizeAway(abi.key_msg)") == null);
}

test "sidecar-selected root names get the wiring's fixed spellings as aliases" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"Model\"", "\"State\"");
    source = try std.mem.replaceOwned(u8, arena, source, "\"slot\": \"Model.count\"", "\"slot\": \"State.count\"");
    source = try std.mem.replaceOwned(u8, arena, source, "\"name\": \"Msg\"", "\"name\": \"Event\"");
    const generated = try emitFromJson(arena, source);
    // The host wiring re-exports core.Model/core.Msg by those exact
    // spellings; the aliases keep a renamed contract compilable.
    try testing.expect(std.mem.indexOf(u8, generated, "pub const Model = State;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const Msg = Event;") != null);
    // The default names alias nothing (a self-alias would not compile).
    const default_generated = try emitFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expect(std.mem.indexOf(u8, default_generated, "pub const Model = Model;") == null);
    try testing.expect(std.mem.indexOf(u8, default_generated, "pub const Msg = Msg;") == null);
}

test "channel detection names are reserved even when the channel is absent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // channels.frame_msg is false in the minimal sidecar, but the host
    // probes the DECL name — a type called frameMsg would falsely wire
    // the channel and then fail as a non-function.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"frameMsg\", \"members\": [\"a\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"frameMsg\"}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "\"frameMsg\" collides") != null) found = true;
    }
    try testing.expect(found);
}

test "a chrome arm holding its insets by reference refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The host constructs the chrome record BY VALUE field by field; a
    // node (by-reference) insets record cannot take that construction.
    const source =
        \\{
        \\  "format": 1, "wire_version": 7, "abi_version": 2,
        \\  "compiler_version": "0.0.1", "entry": "src/core.ts",
        \\  "source_hash": "00000000c0ffee00", "build_id": "00000000b01dface", "model_fingerprint": "00000000a11ce001",
        \\  "types": {
        \\    "structs": [
        \\      {"name": "Model", "fields": [{"name": "chromeTop", "type": {"kind": "f64"}}]},
        \\      {"name": "Insets", "fields": [
        \\        {"name": "top", "type": {"kind": "f64"}}, {"name": "right", "type": {"kind": "f64"}},
        \\        {"name": "bottom", "type": {"kind": "f64"}}, {"name": "left", "type": {"kind": "f64"}}
        \\      ]},
        \\      {"name": "Buttons", "fields": [
        \\        {"name": "x", "type": {"kind": "f64"}}, {"name": "y", "type": {"kind": "f64"}},
        \\        {"name": "width", "type": {"kind": "f64"}}, {"name": "height", "type": {"kind": "f64"}}
        \\      ]},
        \\      {"name": "Msg_chrome_changed", "fields": [
        \\        {"name": "insets", "type": {"kind": "node", "name": "Insets"}},
        \\        {"name": "buttons", "type": {"kind": "value", "name": "Buttons"}},
        \\        {"name": "tabsProjected", "type": {"kind": "bool"}}
        \\      ]}
        \\    ],
        \\    "enums": [], "unions": []
        \\  },
        \\  "model": "Model", "model_helpers": [], "model_unbound": [],
        \\  "msg": {"name": "Msg", "arms": [
        \\    {"name": "chrome_changed", "payload": {"kind": "record", "name": "Msg_chrome_changed"}}
        \\  ], "unbound": []},
        \\  "init_returns_cmd": false, "update_returns_cmd": true, "has_subscriptions": false, "has_migrate": false,
        \\  "channels": {"command_msg": false, "frame_msg": false, "key_msg": false, "pinch_msg": false, "drop_msg": false,
        \\    "appearance_msg": null, "chrome_msg": "chrome_changed", "env_msgs": []},
        \\  "abi": {"prefix": "nsc_core_", "exports": ["abi_version", "build_id", "set_panic_sink", "init",
        \\    "collect", "frame_reset", "boot_cmd", "dispatch_void", "dispatch_bytes", "dispatch_number",
        \\    "dispatch_number_bytes", "dispatch_bool", "dispatch_enum", "dispatch_record",
        \\    "dispatch_text_input", "dispatch_scroll_state", "subscriptions", "model_snapshot",
        \\    "persist_snapshot", "restore_model", "migrate_model", "helper_call"], "snapshot_format": 1},
        \\  "integer_slots": [], "deterministic": true, "async_free": true
        \\}
    ;
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "insets: top/right/bottom/left numbers") != null) found = true;
    }
    try testing.expect(found);
}

test "the shim restates the module-graph attestations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const generated = try emitFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const deterministic: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const async_free: bool = true;") != null);
}

test "number_bytes mirrors number-first; other orders ride the record family" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Family 4 carries no order fact, so the mirror emits the one
    // order every producer of this shape declares (SCHEMA-GAPS.md
    // records the missing fact and its closure). A bytes-first record
    // is still fully expressible: the record family's table entry
    // carries order explicitly — the documented route, pinned here.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Msg_loaded\", \"fields\": [{\"name\": \"body\", \"type\": {\"kind\": \"bytes\"}}, {\"name\": \"status\", \"type\": {\"kind\": \"f64\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"loaded\", \"payload\": {\"kind\": \"record\", \"name\": \"Msg_loaded\"}}",
    );
    const generated = try emitFromJson(arena, source);
    // Declared order preserved exactly: bytes first, number second.
    try testing.expect(std.mem.indexOf(u8, generated, "loaded: struct { body: []const u8, status: f64 },") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_record(0,") != null);
}

test "a single-use pattern-named record inlines to mirror the emitted module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A legacy null-origin sidecar retains the pattern fallback: this is
    // the shape every real anonymous record in the older conformance
    // corpus takes, and a named declaration here would skew its artifacts.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Msg_loaded\", \"fields\": [{\"name\": \"status\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"ok\", \"type\": {\"kind\": \"bool\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"loaded\", \"payload\": {\"kind\": \"record\", \"name\": \"Msg_loaded\"}}",
    );
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "loaded: struct { status: f64, ok: bool },") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const Msg_loaded") == null);
}

test "a single-use authored pattern-named record stays declared by provenance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Msg_loaded\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"status\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"ok\", \"type\": {\"kind\": \"bool\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"loaded\", \"member\": \"payload\", \"payload\": {\"kind\": \"record\", \"name\": \"Msg_loaded\"}}",
    );
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const Msg_loaded = struct") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "loaded: Msg_loaded,") != null);
}

test "keywords and exotic names are quoted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "error", "test", "u8", "1abc", "_", "_x", "super", "chatScrollTop" }, 0..) |name, index| {
        const source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "label", name);
        const generated = try emitFromJson(arena, source);
        const field = if (index < 5)
            try std.fmt.allocPrint(arena, "@\"{s}\": []const u8", .{name})
        else
            try std.fmt.allocPrint(arena, "{s}: []const u8", .{name});
        try testing.expect(std.mem.indexOf(u8, generated, field) != null);
        const tree = try std.zig.Ast.parse(arena, try arena.dupeZ(u8, generated), .zig);
        try testing.expectEqual(@as(usize, 0), tree.errors.len);
    }
}

test "an appearance channel on a wrong-shaped arm refuses with a teaching" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // An enum payload passes the schema's named-type-family rule (V9)
    // but the host cannot build the appearance record into it.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"Phase\", \"members\": [\"a\", \"b\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"enum\", \"name\": \"Phase\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"appearance_msg\": null", "\"appearance_msg\": \"bump\"");
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "colorScheme: a light/dark enum") != null) found = true;
    }
    try testing.expect(found);
}
