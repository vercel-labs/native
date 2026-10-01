const std = @import("std");
const sidecar_mod = @import("sidecar.zig");
const profile = @import("profile.zig");
const emitProfile = profile.emitProfile;
const default_entry = profile.default_entry;

const testing = std.testing;

fn profileFromJson(arena: std.mem.Allocator, json: []const u8, entry: []const u8) ![]const u8 {
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, json, &diags);
    return emitProfile(arena, parsed, entry, "release", &diags);
}

test "profile emission is deterministic and carries the library-mode surface" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try profileFromJson(arena, sidecar_mod.minimal_valid_json, default_entry);
    const second = try profileFromJson(arena, sidecar_mod.minimal_valid_json, default_entry);
    try testing.expectEqualStrings(first, second);
    try testing.expect(std.mem.indexOf(u8, first, "\"profile_format\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"entry\": \"core_facade.ts\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"optimization\": \"release\"") != null);
    var dev_diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed_for_dev = try sidecar_mod.read(arena, sidecar_mod.minimal_valid_json, &dev_diags);
    const dev = try emitProfile(arena, parsed_for_dev, default_entry, "dev", &dev_diags);
    try testing.expect(std.mem.indexOf(u8, dev, "\"optimization\": \"dev\"") != null);
    // Mode symbols ride the abi block under the contract's prefix.
    try testing.expect(std.mem.indexOf(u8, first, "\"init_symbol\": \"nsc_core_init\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"sink_register_symbol\": \"nsc_core_set_panic_sink\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"collect_symbol\": \"nsc_core_collect\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"result_reset_symbol\": \"nsc_core_frame_reset\"") != null);
    // The export map binds the facade's exported function name to the
    // prefixed symbol with the marshalled signature; mode symbols and
    // identity getters stay out of it.
    try testing.expect(std.mem.indexOf(u8, first, "{ \"export\": \"dispatch_number\", \"symbol\": \"nsc_core_dispatch_number\", \"params\": [\"u8\", \"f64\"], \"returns\": \"bytes\" }") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"export\": \"init\"") == null);
    try testing.expect(std.mem.indexOf(u8, first, "\"export\": \"build_id\"") == null);
    // The fixed ABI entry must not take the author-facing
    // `subscriptions` spelling: the sidecar emitter treats an export under
    // that name as a real subscription declaration even when the profile
    // deliberately carries no subscriptions_export designation.
    try testing.expect(std.mem.indexOf(u8, first, "{ \"export\": \"abi_subscriptions\", \"symbol\": \"nsc_core_subscriptions\", \"params\": [], \"returns\": \"bytes\" }") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"export\": \"subscriptions\"") == null);
    // The sidecar section echoes the contract's generations and
    // declares the SDK's emission path, identity-getter symbols, the
    // facade's designated entries, and the integer-slot declarations.
    try testing.expect(std.mem.indexOf(u8, first, "\"path\": \"core.contract.json\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"wire_version\": 7") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"build_id_symbol\": \"nsc_core_build_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"abi_version_symbol\": \"nsc_core_abi_version\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"init_export\": \"init\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"update_export\": \"coreUpdate\"") != null);
    // minimal_valid_json has no subscriptions: the designation must not
    // dangle (the compiler refuses a name that resolves to nothing).
    try testing.expect(std.mem.indexOf(u8, first, "subscriptions_export") == null);
    // The integer-slot declarations carry through from the contract.
    try testing.expect(std.mem.indexOf(u8, first, "{ \"slot\": \"Model.count\", \"class\": \"i64\" }") != null);
    // No provenance stub rides the profile (the compiler computes its
    // own source hash over the module graph).
    try testing.expect(std.mem.indexOf(u8, first, "source_hash") == null);
    // The determinism policy rides whole: fences with SDK teachings,
    // the shared async teaching, the trap remediations.
    try testing.expect(std.mem.indexOf(u8, first, "{ \"id\": \"stdlib.math.random\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "{ \"prefix\": \"node-builtin.fs.\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"async\":") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"SC4013\":") != null);
}

test "wired channels join the export map with their wire shapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"key_msg\": false", "\"key_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"pinch_msg\": false", "\"pinch_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"drop_msg\": false", "\"drop_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"helper_call\"]", "\"helper_call\", \"key_msg\", \"pinch_msg\", \"drop_msg\"]");
    const generated = try profileFromJson(arena, source, default_entry);
    // The wire-shaped signatures: bytes as buffers, u8 modifier
    // booleans, the pinch phase a u32 member index. The export names
    // take the facade's abi_ spellings; the symbols the contract's
    // prefix.
    try testing.expect(std.mem.indexOf(u8, generated, "{ \"export\": \"abi_key_msg\", \"symbol\": \"nsc_core_key_msg\", \"params\": [\"bytes\", \"u8\", \"u8\", \"u8\", \"u8\"], \"returns\": \"bytes\" }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ \"export\": \"abi_pinch_msg\", \"symbol\": \"nsc_core_pinch_msg\", \"params\": [\"f64\", \"bytes\", \"u32\", \"f64\", \"f64\", \"f64\"], \"returns\": \"bytes\" }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ \"export\": \"abi_drop_msg\", \"symbol\": \"nsc_core_drop_msg\", \"params\": [\"bytes\"], \"returns\": \"bytes\" }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "abi_command_msg") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "abi_frame_msg") == null);
}

test "the profile tracks the contract's prefix and generations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"prefix\": \"nsc_core_\"", "\"prefix\": \"app2_\"");
    source = try std.mem.replaceOwned(u8, arena, source, "\"wire_version\": 7", "\"wire_version\": 7");
    const generated = try profileFromJson(arena, source, "my_facade.ts");
    try testing.expect(std.mem.indexOf(u8, generated, "\"entry\": \"my_facade.ts\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "\"prefix\": \"app2_\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "\"init_symbol\": \"app2_init\"") != null);
    // Export names keep the facade's own function spellings; only the
    // symbols take the contract's prefix.
    try testing.expect(std.mem.indexOf(u8, generated, "{ \"export\": \"model_snapshot\", \"symbol\": \"app2_model_snapshot\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ \"export\": \"persist_snapshot\", \"symbol\": \"app2_persist_snapshot\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "\"export\": \"app2_") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "\"build_id_symbol\": \"app2_build_id\"") != null);
}

test "a non-UTF-8 entry spelling refuses instead of corrupting the JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, sidecar_mod.minimal_valid_json, &diags);
    try testing.expectError(error.Refused, emitProfile(arena, parsed, "core_\xfffacade.ts", "release", &diags));
}

test "a contract attesting false for an enforced posture refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]struct { needle: []const u8, replacement: []const u8, fragment: []const u8 }{
        .{ .needle = "\"deterministic\": true", .replacement = "\"deterministic\": false", .fragment = "attests deterministic: false" },
        .{ .needle = "\"async_free\": true", .replacement = "\"async_free\": false", .fragment = "attests async_free: false" },
    }) |case| {
        const source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, case.needle, case.replacement);
        var diags = sidecar_mod.Diagnostics{ .arena = arena };
        const parsed = try sidecar_mod.read(arena, source, &diags);
        try testing.expectError(error.Refused, emitProfile(arena, parsed, default_entry, "release", &diags));
        var found = false;
        for (diags.list.items) |item| {
            if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, case.fragment) != null) found = true;
        }
        try testing.expect(found);
    }
}
