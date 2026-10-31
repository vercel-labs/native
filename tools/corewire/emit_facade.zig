//! Compiled TypeScript projection over the native structural decoder.
const std = @import("std");
const sidecar_mod = @import("sidecar.zig");
const Sidecar = sidecar_mod.Sidecar;
pub const Error = error{ Refused, OutOfMemory };

pub fn emitFacade(arena: std.mem.Allocator, sidecar: Sidecar, diags: *sidecar_mod.Diagnostics) Error![]const u8 {
    return @import("core_emission.zig").emit(arena, sidecar, .facade, diags);
}

const testing = std.testing;
// Retained native fixtures exercise both authored scroll spellings.
const scroll_state_fields_ts = [_][]const u8{
    "offsetX",         "offsetY",         "velocityX",      "velocityY",
    "viewportExtentX", "viewportExtentY", "contentExtentX", "contentExtentY",
};
const scroll_state_fields_canvas = [_][]const u8{
    "offset_x",          "offset_y",          "velocity_x",       "velocity_y",
    "viewport_extent_x", "viewport_extent_y", "content_extent_x", "content_extent_y",
};

/// Most facade tests perturb sidecar_mod's deliberately LEGACY minimal
/// fixture. Upgrade its two authored facts here so unrelated refusal tests
/// exercise the current facade boundary; the dedicated legacy test below
/// calls emitFacade directly on the untouched fixture.
fn withCurrentFacadeFacts(arena: std.mem.Allocator, json: []const u8) ![]const u8 {
    var current = json;
    const model = "{\"name\": \"Model\", \"fields\":";
    if (std.mem.indexOf(u8, current, model) != null) {
        current = try std.mem.replaceOwned(u8, arena, current, model, "{\"name\": \"Model\", \"origin\": \"core.ts\", \"fields\":");
    }
    const label_arm = "{\"name\": \"label_set\", \"payload\": {\"kind\": \"bytes\"}}";
    if (std.mem.indexOf(u8, current, label_arm) != null) {
        current = try std.mem.replaceOwned(u8, arena, current, label_arm, "{\"name\": \"label_set\", \"member\": \"value\", \"payload\": {\"kind\": \"bytes\"}}");
    }
    return current;
}

fn facadeFromJson(arena: std.mem.Allocator, json: []const u8) ![]const u8 {
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = sidecar_mod.read(arena, try withCurrentFacadeFacts(arena, json), &diags) catch |err| {
        for (diags.list.items) |item| {
            std.debug.print("  [{s}] {s}: {s}\n", .{ @tagName(item.severity), item.path, item.message });
        }
        return err;
    };
    return emitFacade(arena, parsed, &diags) catch |err| {
        for (diags.list.items) |item| {
            std.debug.print("  [{s}] {s}: {s}\n", .{ @tagName(item.severity), item.path, item.message });
        }
        return err;
    };
}

fn expectFacadeRefusal(arena: std.mem.Allocator, json: []const u8, fragment: []const u8) !void {
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, try withCurrentFacadeFacts(arena, json), &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, fragment) != null) return;
    }
    std.debug.print("no refusal containing \"{s}\"; got:\n", .{fragment});
    for (diags.list.items) |item| {
        std.debug.print("  [{s}] {s}: {s}\n", .{ @tagName(item.severity), item.path, item.message });
    }
    return error.TestExpectedRefusal;
}

test "legacy sidecars remain mirror-readable but refuse facade projection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, sidecar_mod.minimal_valid_json, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var taught_origin = false;
    var taught_member = false;
    for (diags.list.items) |item| {
        if (std.mem.indexOf(u8, item.message, "type-origin fact") != null) taught_origin = true;
        if (std.mem.indexOf(u8, item.message, "member-name fact") != null) taught_member = true;
    }
    try testing.expect(taught_origin);
    try testing.expect(taught_member);
}

test "facade emission is deterministic and carries the adapter surface" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try facadeFromJson(arena, sidecar_mod.minimal_valid_json);
    const second = try facadeFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expectEqualStrings(first, second);
    // The author's behavioral exports import under nscf aliases from the
    // entry module; the contract types re-export from it.
    try testing.expect(std.mem.indexOf(u8, first, "initialModel as nscfInitialModel,") != null);
    try testing.expect(std.mem.indexOf(u8, first, "update as nscfUpdate,") != null);
    try testing.expect(std.mem.indexOf(u8, first, "} from \"./core.ts\";") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export type { Model, Msg } from \"./core.ts\";") != null);
    // The designated shape-flag entries restate the contract's flags.
    try testing.expect(std.mem.indexOf(u8, first, "export function init(): Model {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export function coreUpdate(model: Model, msg: Msg): [Model, Uint8Array] {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "coreSubscriptions") == null);
    // The dispatch surface: committed state, tag table, arm routing.
    try testing.expect(std.mem.indexOf(u8, first, "let nscfCommitted: Model = nscfInitialModel();") != null);
    try testing.expect(std.mem.indexOf(u8, first, "const nscfTag_bump = 0;") != null);
    try testing.expect(std.mem.indexOf(u8, first, "if (tag === nscfTag_bump) return nscfCommit(coreUpdate(nscfCommitted, { kind: \"bump\" }));") != null);
    try testing.expect(std.mem.indexOf(u8, first, "if (tag === nscfTag_label_set) return nscfCommit(coreUpdate(nscfCommitted, { kind: \"label_set\", value: payload }));") != null);
    // Post-cycle: the snapshot is a tagged, length-delimited root record;
    // each field payload rides the generated canonical writer with its
    // attested integer class.
    try testing.expect(std.mem.indexOf(u8, first, "nscfWI64(sink, value.count);") != null);
    try testing.expect(std.mem.indexOf(u8, first, "function nscfSnapshotModel(value: Model): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "nscfWU32(sink, 2);") != null);
    try testing.expect(std.mem.indexOf(u8, first, "nscfWBytes(sink, nscfFinish(nscfFieldSink0));") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export function abi_subscriptions(): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export function subscriptions(): Uint8Array {") == null);
    try testing.expect(std.mem.indexOf(u8, first, "export function model_snapshot(): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export function persist_snapshot(): Uint8Array {") != null);
    // The unbound list restates the author's markings.
    try testing.expect(std.mem.indexOf(u8, first, "export const viewUnbound = [\n  \"label_set\",\n];") != null);
    // Unwired channels stay out of the module.
    try testing.expect(std.mem.indexOf(u8, first, "abi_frame_msg") == null);
    try testing.expect(std.mem.indexOf(u8, first, "function nscfPackMsg") != null);
    // Facade-only types, tag constants, and SDK effect imports all live in
    // the lowercase reserved namespace, so authored capitalized names cannot
    // collide with them.
    try testing.expect(std.mem.indexOf(u8, first, "type nscfSink = number[];") != null);
    try testing.expect(std.mem.indexOf(u8, first, "import type { Cmd as nscfCmd, DbText as nscfDbText }") != null);
    try testing.expect(std.mem.indexOf(u8, first, "Number.isInteger(value) && value >= 0 && value <= 256 ? value : 257") != null);
    try testing.expect(std.mem.indexOf(u8, first, "nscfWU32(sink, nscfStoreScanLimit(cmd.limit));") != null);
    try testing.expect(std.mem.indexOf(u8, first, "NscfSink") == null);
    try testing.expect(std.mem.indexOf(u8, first, "NSCF_TAG_") == null);
}

test "migration hooks produce a closed status-prefixed snapshot seam" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"has_migrate\": false", "\"has_migrate\": true");
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "migrate as nscfMigrate,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export function migrate_model(snapshot: Uint8Array, fromVersion: number): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "const migrated = nscfMigrate(snapshot, fromVersion);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "const body = nscfSnapshotModel(migrated);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "out[0] = 1;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "catch {") != null);
}

test "member facts spell the author's payload property names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"toggle\", \"member\": \"taskId\", \"payload\": {\"kind\": \"number\", \"class\": \"i64\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Msg.toggle\", \"class\": \"i64\"}");
    const generated = try facadeFromJson(arena, source);
    // The integer-classed arm proves in place with the authored member
    // spelling at the write.
    try testing.expect(std.mem.indexOf(u8, generated, "if (value >= -9007199254740991 && value <= 9007199254740991) {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "const whole = Math.trunc(value);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ kind: \"toggle\", taskId: whole }") != null);
    // The baseline's own member fact remains authoritative too.
    try testing.expect(std.mem.indexOf(u8, generated, "{ kind: \"label_set\", value: payload }") != null);
}

test "origin facts group re-exports by declaring module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"structs\": [",
        "\"structs\": [\n      {\"name\": \"Turn\", \"origin\": \"domain/api.ts\", \"fields\": [{\"name\": \"id\", \"type\": {\"kind\": \"f64\"}}]},",
    );
    const with_field = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"node\", \"name\": \"Turn\"}}",
    );
    const generated = try facadeFromJson(arena, with_field);
    try testing.expect(std.mem.indexOf(u8, generated, "export type { Turn } from \"./domain/api.ts\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export type { Model, Msg } from \"./core.ts\";") != null);
    // The generated snapshot writer reaches the record through its
    // named writer, importing the type from its own module.
    try testing.expect(std.mem.indexOf(u8, generated, "import type { Turn } from \"./domain/api.ts\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "function nscfWriteTurn(sink: nscfSink, value: Turn): void {") != null);
}

test "private reachable types get structural twins instead of invalid imports" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"structs\": [",
        "\"structs\": [\n      {\"name\": \"Hidden\", \"origin\": \"core.ts\", \"exported\": false, \"fields\": [{\"name\": \"value\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"mode\", \"type\": {\"kind\": \"enum\", \"name\": \"HiddenMode\"}}, {\"name\": \"state\", \"type\": {\"kind\": \"union\", \"name\": \"HiddenState\"}}]},",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"enums\": []", "\"enums\": [{\"name\": \"HiddenMode\", \"origin\": \"core.ts\", \"exported\": false, \"members\": [\"one\", \"two\"]}]");
    source = try std.mem.replaceOwned(u8, arena, source, "\"unions\": []", "\"unions\": [{\"name\": \"HiddenState\", \"origin\": \"core.ts\", \"exported\": false, \"arms\": [{\"name\": \"off\", \"payload\": {\"kind\": \"void\"}}, {\"name\": \"on\", \"member\": \"level\", \"payload\": {\"kind\": \"f64\"}}]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"hidden\", \"type\": {\"kind\": \"node\", \"name\": \"Hidden\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "import type { Model, Msg } from \"./core.ts\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "import type { Model, Msg, Hidden }") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "export type { Model, Msg, Hidden }") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "type Hidden = {\n  readonly value: number;\n  readonly mode: HiddenMode;\n  readonly state: HiddenState;\n};") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "type HiddenMode = \"one\" | \"two\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "type HiddenState =\n  | { readonly kind: \"off\" }\n  | { readonly kind: \"on\"; readonly level: number }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "function nscfWriteHidden(sink: nscfSink, value: Hidden): void {") != null);
}

test "generated generic table names refuse before emitting invalid imports" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"Model\", \"fields\": [",
        "{\"name\": \"Model\", \"origin\": \"core.ts\", \"fields\": [",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "\"structs\": [",
        "\"structs\": [\n      {\"name\": \"Item\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"value\", \"type\": {\"kind\": \"f64\"}}]},\n      {\"name\": \"Box__Item\", \"fields\": [{\"name\": \"item\", \"type\": {\"kind\": \"node\", \"name\": \"Item\"}}]},",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"box\", \"type\": {\"kind\": \"node\", \"name\": \"Box__Item\"}}",
    );
    // The monomorphized name is not an authored export, and the external
    // library compiler cannot project the generic contract field either.
    // Refuse here instead of generating `import type { Box__Item }` and
    // deferring failure to the TypeScript/compiler boundary.
    try expectFacadeRefusal(arena, source, "generic instantiations cannot cross the compiled-core contract surface yet");
}

test "helpers wrap in declaration order with classed-return proofs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"summary\", \"params\": [], \"returns\": {\"kind\": \"bytes\"}, \"arena\": false}, {\"name\": \"rowCount\", \"params\": [], \"returns\": {\"kind\": \"i64\"}, \"arena\": false}]",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"helpers.rowCount.return\", \"class\": \"i64\"}");
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "summary as nscfH_summary,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export function summary(model: Model): Uint8Array {") != null);
    // The classed return binds, guards, and truncs at the boundary.
    try testing.expect(std.mem.indexOf(u8, generated, "export function rowCount(model: Model): number {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "const nscfValue = nscfH_rowCount(model);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (nscfValue >= -9007199254740991 && nscfValue <= 9007199254740991) return Math.trunc(nscfValue);") != null);
    // helper_call indexes the declaration order and encodes each result
    // in its declared return encoding.
    try testing.expect(std.mem.indexOf(u8, generated, "if (helper === 0) {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (helper === 1) {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfWBytes(sink, nscfValue);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfWI64(sink, nscfValue);") != null);
}

test "themeState helper encodes omitted fields and UTF-8 string accent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"structs\": [",
        "\"structs\": [\n      {\"name\": \"ThemeState\", \"origin\": \"sdk/events.ts\", \"fields\": [{\"name\": \"pack\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"enum\", \"name\": \"ThemeStatePack\"}}}, {\"name\": \"colorScheme\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"enum\", \"name\": \"ThemeStateColorScheme\"}}}, {\"name\": \"accent\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"bytes\"}}}] },",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "\"enums\": []",
        "\"enums\": [{\"name\": \"ThemeStatePack\", \"origin\": \"sdk/events.ts\", \"members\": [\"house\", \"geist\"]}, {\"name\": \"ThemeStateColorScheme\", \"origin\": \"sdk/events.ts\", \"members\": [\"light\", \"dark\", \"system\"]}]",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"themeState\", \"params\": [], \"returns\": {\"kind\": \"value\", \"name\": \"ThemeState\"}, \"arena\": false}]",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "=== null ||") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "=== undefined") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfWBytes(sink, nscfUtf8TextBytes(") != null);
}

test "nullable integer helper returns prove their present branch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"maybeCount\", \"params\": [], \"returns\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"i64\"}}, \"arena\": false}]",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"helpers.maybeCount.return\", \"class\": \"i64\"}");
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "export function maybeCount(model: Model): number | null {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (nscfValue === null) return null;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (nscfValue >= -9007199254740991 && nscfValue <= 9007199254740991) return Math.trunc(nscfValue);") != null);
}

test "wired channels emit abi entries and the generic payload packer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"key_msg\": false", "\"key_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"frame_msg\": false", "\"frame_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"helper_call\"]", "\"helper_call\", \"frame_msg\", \"key_msg\"]");
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "frameMsg as nscfChanFrameMsg,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "keyMsg as nscfChanKeyMsg,") != null);
    // The frame gate receives the committed model; the key gate the
    // event record with the wire's 0-or-1 modifier conversion.
    try testing.expect(std.mem.indexOf(u8, generated, "export function abi_frame_msg(width: number, height: number, timestampMs: number, intervalMs: number): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfPackMsg(nscfChanFrameMsg(nscfCommitted, {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "shift: shift !== 0,") != null);
    // The envelope: [produced u8][tag u8][canonical payload].
    try testing.expect(std.mem.indexOf(u8, generated, "if (produced === null) return new Uint8Array(2);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "out[1] = nscfTagOf(produced.kind);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "function nscfMsgPayload(sink: nscfSink, value: Msg): void {") != null);
    // The unwired channels stay out.
    try testing.expect(std.mem.indexOf(u8, generated, "abi_pinch_msg") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "abi_command_msg") == null);
}

test "scalar primitive message payload aliases share dispatch and channel encoders" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"label_set\", \"payload\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"blob\", \"member\": \"blob\", \"payload\": {\"kind\": \"scalar\", \"type\": {\"kind\": \"bytes\"}}}, {\"name\": \"ratio\", \"member\": \"ratio\", \"payload\": {\"kind\": \"scalar\", \"type\": {\"kind\": \"f64\"}}}, {\"name\": \"count_set\", \"member\": \"count\", \"payload\": {\"kind\": \"scalar\", \"type\": {\"kind\": \"i64\"}}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"unbound\": [\"label_set\"]", "\"unbound\": []");
    source = try std.mem.replaceOwned(u8, arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Msg.count_set\", \"class\": \"i64\"}");
    source = try std.mem.replaceOwned(u8, arena, source, "\"key_msg\": false", "\"key_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"helper_call\"]", "\"helper_call\", \"key_msg\"]");

    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "if (tag === nscfTag_blob) return nscfCommit(coreUpdate(nscfCommitted, { kind: \"blob\", blob: payload }));") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (tag === nscfTag_ratio) return nscfCommit(coreUpdate(nscfCommitted, { kind: \"ratio\", ratio: value }));") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (tag === nscfTag_count_set) {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfWBytes(sink, value.blob);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfWF64(sink, value.ratio);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfWI64(sink, value.count);") != null);
}

test "u64-attested slots ride the unsigned writer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"u64\"}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfWU64(sink, value.count);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "function nscfWU64(sink: nscfSink, value: number): void {") != null);
    const signed = try facadeFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expect(std.mem.indexOf(u8, signed, "nscfWU64") == null);
}

test "u64 attestations set nonnegative proofs on every ingress shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Payload\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"id\", \"type\": {\"kind\": \"i64\"}}]},");
    source = try std.mem.replaceOwned(u8, arena, source, "\"model_helpers\": []", "\"model_helpers\": [{\"name\": \"nextId\", \"params\": [], \"returns\": {\"kind\": \"i64\"}, \"arena\": false}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"id_set\", \"member\": \"value\", \"payload\": {\"kind\": \"number\", \"class\": \"i64\"}}, {\"name\": \"loaded\", \"member\": \"payload\", \"payload\": {\"kind\": \"record\", \"name\": \"Payload\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "{\"name\": \"label_set\", \"payload\": {\"kind\": \"bytes\"}}", "{\"name\": \"sized\", \"payload\": {\"kind\": \"number_bytes\", \"number_field\": \"size\", \"number_class\": \"i64\", \"bytes_field\": \"label\"}}");
    source = try std.mem.replaceOwned(u8, arena, source, "\"unbound\": [\"label_set\"]", "\"unbound\": [\"id_set\", \"loaded\", \"sized\"]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Msg.id_set\", \"class\": \"u64\"}, {\"slot\": \"Msg.sized.size\", \"class\": \"u64\"}, {\"slot\": \"Payload.id\", \"class\": \"u64\"}, {\"slot\": \"helpers.nextId.return\", \"class\": \"u64\"}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "if (tag === nscfTag_id_set) {\n    if (value >= 0 && value <= 9007199254740991) {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (tag === nscfTag_sized) {\n    // The number field is i64-classed") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (value >= 0 && value <= 9007199254740991) {\n      return nscfCommit(coreUpdate(nscfCommitted, { kind: \"sized\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (nscfValue >= 0 && nscfValue <= 9007199254740991) return Math.trunc(nscfValue);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (nscfV0 >= 0 && nscfV0 <= 9007199254740991) {") != null);
}

test "an authored pattern-named record keeps its member and re-export" {
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
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "export type { Model, Msg, Msg_loaded } from \"./core.ts\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ kind: \"loaded\", payload: { status:") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ kind: \"loaded\", status:") == null);
}

test "a helper taking a fixed export's name refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"dispatch_void\", \"params\": [], \"returns\": {\"kind\": \"bytes\"}, \"arena\": false}]",
    );
    try expectFacadeRefusal(arena, source, "collides with a declaration the generated facade itself must export");
}

test "a helper cannot shadow the generated frame channel export" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"abi_frame_msg\", \"params\": [], \"returns\": {\"kind\": \"bytes\"}, \"arena\": false}]",
    );
    try expectFacadeRefusal(arena, source, "collides with a declaration the generated facade itself must export");
}

test "capitalized authored names no longer collide with facade internals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"structs\": [",
        "\"structs\": [\n      {\"name\": \"NscfSink\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"id\", \"type\": {\"kind\": \"f64\"}}]},\n      {\"name\": \"Cmd\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"id\", \"type\": {\"kind\": \"f64\"}}]},",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"sinkValue\", \"type\": {\"kind\": \"node\", \"name\": \"NscfSink\"}}, {\"name\": \"commandValue\", \"type\": {\"kind\": \"node\", \"name\": \"Cmd\"}}",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"NSCF_TAG_bump\", \"params\": [], \"returns\": {\"kind\": \"bytes\"}, \"arena\": false}]",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "import type { Model, Msg, NscfSink, Cmd } from \"./core.ts\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "import type { Cmd as nscfCmd, DbText as nscfDbText } from \"./sdk/core.ts\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export function NSCF_TAG_bump(model: Model): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "const nscfTag_bump = 0;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "type nscfSink = number[];") != null);
}

test "a helper may not shadow an ambient facade value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"Math\", \"params\": [], \"returns\": {\"kind\": \"bytes\"}, \"arena\": false}]",
    );
    try expectFacadeRefusal(arena, source, "shadows an ambient value");
}

test "a payload member spelled kind refuses against the discriminator" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"label_set\", \"payload\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label_set\", \"member\": \"kind\", \"payload\": {\"kind\": \"bytes\"}}",
    );
    try expectFacadeRefusal(arena, source, "the discriminator's own spelling");
}

test "a type in the facade's reserved nsc name space refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"nscfHelper\", \"members\": [\"a\", \"b\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"nscfHelper\"}}",
    );
    try expectFacadeRefusal(arena, source, "reserved nsc name space");
}

test "an unbound message arm shadowed by a homonymous model field refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"count\", \"payload\": {\"kind\": \"void\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"unbound\": [\"label_set\"]", "\"unbound\": [\"count\"]");
    try expectFacadeRefusal(arena, source, "resolves Model fields and helpers before message arms");
}

test "an unbound model field may share a name with a bound message arm" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"count\", \"payload\": {\"kind\": \"void\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"model_unbound\": []", "\"model_unbound\": [\"count\"]");
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "export const viewUnbound = [\n  \"label_set\",\n  \"count\",\n];") != null);
}

test "an unbound message arm shadowed by a homonymous helper refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"bump\", \"params\": [], \"returns\": {\"kind\": \"bool\"}, \"arena\": false}]",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"unbound\": [\"label_set\"]", "\"unbound\": [\"bump\"]");
    try expectFacadeRefusal(arena, source, "resolves Model fields and helpers before message arms");
}

test "nested optionals refuse in the projection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"f64\"}}}}",
    );
    try expectFacadeRefusal(arena, source, "one absence level");
}

test "a record referenced by node and value at once refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Item\", \"fields\": [{\"name\": \"x\", \"type\": {\"kind\": \"f64\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"live\", \"type\": {\"kind\": \"node\", \"name\": \"Item\"}}, {\"name\": \"cached\", \"type\": {\"kind\": \"value\", \"name\": \"Item\"}}",
    );
    try expectFacadeRefusal(arena, source, "storage once per declaration");
}

test "record dispatch decodes nonterminal optionals and nullable composites" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"structs\": [",
        "\"structs\": [\n      {\"name\": \"Payload\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"maybe\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"f64\"}}}, {\"name\": \"tail\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"blob\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"bytes\"}}}]},",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"loaded\", \"member\": \"payload\", \"payload\": {\"kind\": \"record\", \"name\": \"Payload\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "let nscfAt = 0;") != null);
    const optional_at = std.mem.indexOf(u8, generated, "let nscfV1: number | null = null;").?;
    const tail_at = std.mem.indexOfPos(u8, generated, optional_at, "nscfReadF64(fields, nscfAt)").?;
    try testing.expect(tail_at > optional_at);
    try testing.expect(std.mem.indexOf(u8, generated, "Uint8Array | null = null;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfReadBytesBody(fields, nscfAt,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfAssertConsumed(fields, nscfAt);") != null);
}

test "record dispatch recursively decodes sequences and nested unions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"structs\": [",
        "\"structs\": [\n      {\"name\": \"Payload\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"values\", \"type\": {\"kind\": \"slice\", \"elem\": {\"kind\": \"f64\"}}}, {\"name\": \"choice\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"union\", \"name\": \"Choice\"}}}]},",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"unions\": []", "\"unions\": [{\"name\": \"Choice\", \"origin\": \"core.ts\", \"arms\": [{\"name\": \"none\", \"payload\": {\"kind\": \"void\"}}, {\"name\": \"text\", \"member\": \"value\", \"payload\": {\"kind\": \"bytes\"}}]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"loaded\", \"member\": \"payload\", \"payload\": {\"kind\": \"record\", \"name\": \"Payload\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, ": number[] = [];") != null);
    try testing.expect(std.mem.indexOf(u8, generated, ".push(") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfReadU8(fields, nscfAt)") != null);
    try testing.expect(std.mem.indexOf(u8, generated, ": Choice | null = null;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ kind: \"text\", value:") != null);
}

test "ordinary set_selection arms keep exact integer decoding" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"CaretRange\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"anchor\", \"type\": {\"kind\": \"i64\"}}, {\"name\": \"focus\", \"type\": {\"kind\": \"i64\"}}]},");
    source = try std.mem.replaceOwned(u8, arena, source, "\"unions\": []", "\"unions\": [{\"name\": \"Edit\", \"origin\": \"core.ts\", \"arms\": [{\"name\": \"clear\", \"payload\": {\"kind\": \"void\"}}, {\"name\": \"set_selection\", \"member\": \"selection\", \"payload\": {\"kind\": \"value\", \"name\": \"CaretRange\"}}]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"edited\", \"member\": \"edit\", \"payload\": {\"kind\": \"union\", \"name\": \"Edit\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"CaretRange.anchor\", \"class\": \"i64\"}, {\"slot\": \"CaretRange.focus\", \"class\": \"i64\"}");
    const generated = try facadeFromJson(arena, source);
    // The union decodes standalone on the record and text-input entries.
    try testing.expect(std.mem.indexOf(u8, generated, "function nscfDecodeEdit(bytes: Uint8Array): Edit {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ kind: \"edited\", edit: nscfDecodeEdit(fields) }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ kind: \"edited\", edit: nscfDecodeEdit(event) }") != null);
    // This is not the complete text-input protocol, so a homonymous arm
    // retains the ordinary exact reader and rejects out-of-window integers.
    try testing.expect(std.mem.indexOf(u8, generated, "let nscfAt = 1;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfReadI64(bytes, nscfAt)") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfReadI64Saturating") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfReadU64Saturating") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "anchor: Math.trunc(") != null);
}

test "text-input selection saturates signed and unsigned select-all sentinels" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const records =
        \\      {"name": "Move", "origin": "core.ts", "fields": [
        \\        {"name": "direction", "type": {"kind": "enum", "name": "Dir"}},
        \\        {"name": "extend", "type": {"kind": "bool"}}
        \\      ]},
        \\      {"name": "Sel", "origin": "core.ts", "fields": [
        \\        {"name": "anchor", "type": {"kind": "i64"}},
        \\        {"name": "focus", "type": {"kind": "i64"}}
        \\      ]},
        \\      {"name": "Comp", "origin": "core.ts", "fields": [
        \\        {"name": "text", "type": {"kind": "bytes"}},
        \\        {"name": "cursor", "type": {"kind": "optional", "inner": {"kind": "i64"}}}
        \\      ]},
    ;
    const union_entry =
        \\"unions": [{"name": "Edit", "origin": "core.ts", "arms": [
        \\      {"name": "insert_text", "member": "text", "payload": {"kind": "bytes"}},
        \\      {"name": "delete_backward", "payload": {"kind": "void"}},
        \\      {"name": "delete_forward", "payload": {"kind": "void"}},
        \\      {"name": "delete_word_backward", "payload": {"kind": "void"}},
        \\      {"name": "delete_word_forward", "payload": {"kind": "void"}},
        \\      {"name": "delete_to_start", "payload": {"kind": "void"}},
        \\      {"name": "delete_to_line_start", "payload": {"kind": "void"}},
        \\      {"name": "clear", "payload": {"kind": "void"}},
        \\      {"name": "move_caret", "member": "move", "payload": {"kind": "value", "name": "Move"}},
        \\      {"name": "set_selection", "member": "selection", "payload": {"kind": "value", "name": "Sel"}},
        \\      {"name": "set_composition", "member": "composition", "payload": {"kind": "value", "name": "Comp"}},
        \\      {"name": "commit_composition", "payload": {"kind": "void"}},
        \\      {"name": "cancel_composition", "payload": {"kind": "void"}}
        \\    ]}]
    ;
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [\n", try std.fmt.allocPrint(arena, "\"structs\": [\n{s}\n", .{records}));
    source = try std.mem.replaceOwned(u8, arena, source, "\"enums\": []", "\"enums\": [{\"name\": \"Dir\", \"origin\": \"core.ts\", \"members\": [\"previous\", \"next\", \"previous_word\", \"next_word\", \"start\", \"end\"]}]");
    source = try std.mem.replaceOwned(u8, arena, source, "\"unions\": []", union_entry);
    source = try std.mem.replaceOwned(u8, arena, source, "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}", "{\"name\": \"edited\", \"member\": \"edit\", \"payload\": {\"kind\": \"union\", \"name\": \"Edit\"}}");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Sel.anchor\", \"class\": \"u64\"}, {\"slot\": \"Sel.focus\", \"class\": \"i64\"}, {\"slot\": \"Comp.cursor\", \"class\": \"u64\"}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfReadU64Saturating(bytes, nscfAt)") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfReadI64Saturating(bytes, nscfAt)") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "function nscfReadU64Saturating(bytes: Uint8Array, at: number): number {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (hi > 2097151) return 9007199254740991;") != null);
}

test "scroll-shaped record arms answer the dedicated scroll entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"ScrollState\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"offsetX\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"offsetY\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"velocityX\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"velocityY\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"viewportExtentX\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"viewportExtentY\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"contentExtentX\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"contentExtentY\", \"type\": {\"kind\": \"f64\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"scrolled\", \"member\": \"scroll\", \"payload\": {\"kind\": \"record\", \"name\": \"ScrollState\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    // Both routes: the generic record decode and the flat-scalar entry.
    try testing.expect(std.mem.indexOf(u8, generated, "if (tag === nscfTag_scrolled) return nscfCommit(coreUpdate(nscfCommitted, { kind: \"scrolled\", scroll: { offsetX: offsetX, offsetY: offsetY, velocityX: velocityX, velocityY: velocityY, viewportExtentX: viewportExtentX, viewportExtentY: viewportExtentY, contentExtentX: contentExtentX, contentExtentY: contentExtentY } }));") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfUnknownTag(\"scroll-state\", tag);") != null);

    var integer_source = try std.mem.replaceOwned(u8, arena, source, "{\"name\": \"offsetX\", \"type\": {\"kind\": \"f64\"}}", "{\"name\": \"offsetX\", \"type\": {\"kind\": \"i64\"}}");
    integer_source = try std.mem.replaceOwned(u8, arena, integer_source, "{\"name\": \"offsetY\", \"type\": {\"kind\": \"f64\"}}", "{\"name\": \"offsetY\", \"type\": {\"kind\": \"i64\"}}");
    integer_source = try std.mem.replaceOwned(u8, arena, integer_source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"ScrollState.offsetX\", \"class\": \"u64\"}, {\"slot\": \"ScrollState.offsetY\", \"class\": \"i64\"}");
    const integer_generated = try facadeFromJson(arena, integer_source);
    try testing.expect(std.mem.indexOf(u8, integer_generated, "offsetX >= 0 && offsetX <= 9007199254740991 && offsetY >= -9007199254740991 && offsetY <= 9007199254740991") != null);
    try testing.expect(std.mem.indexOf(u8, integer_generated, "offsetX: Math.trunc(offsetX), offsetY: Math.trunc(offsetY)") != null);

    // The canvas snake_case vocabulary routes through the same ABI entry,
    // with each authored field fed by its corresponding camelCase ABI param.
    var snake_source = source;
    for (scroll_state_fields_ts, scroll_state_fields_canvas) |ts_name, canvas_name| {
        snake_source = try std.mem.replaceOwned(u8, arena, snake_source, ts_name, canvas_name);
    }
    const snake_generated = try facadeFromJson(arena, snake_source);
    try testing.expect(std.mem.indexOf(u8, snake_generated, "offset_x: offsetX, offset_y: offsetY, velocity_x: velocityX, velocity_y: velocityY") != null);

    // A current sidecar's originless pattern-named arm record is the
    // compiler's inline shape: scroll construction flattens beside kind
    // rather than inventing a `value` payload member.
    var inline_source = try std.mem.replaceOwned(u8, arena, source, "{\"name\": \"Model\", \"fields\": [", "{\"name\": \"Model\", \"origin\": \"core.ts\", \"fields\": [");
    inline_source = try std.mem.replaceOwned(u8, arena, inline_source, "ScrollState", "Msg_scrolled");
    inline_source = try std.mem.replaceOwned(u8, arena, inline_source, "{\"name\": \"Msg_scrolled\", \"origin\": \"core.ts\"", "{\"name\": \"Msg_scrolled\"");
    inline_source = try std.mem.replaceOwned(u8, arena, inline_source, "\"member\": \"scroll\", ", "");
    const inline_generated = try facadeFromJson(arena, inline_source);
    try testing.expect(std.mem.indexOf(u8, inline_generated, "{ kind: \"scrolled\", offsetX: offsetX, offsetY: offsetY") != null);
    try testing.expect(std.mem.indexOf(u8, inline_generated, "{ kind: \"scrolled\", value:") == null);
}
