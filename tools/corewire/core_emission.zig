//! Structural facts and owned copies at the compiled generator boundary.
const std = @import("std");
const sidecar_mod = @import("sidecar.zig");
const PanicSink = *const fn (?*anyopaque, [*]const u8, usize, u64) callconv(.c) void;
extern fn nsc_profile_set_panic_sink(PanicSink, ?*anyopaque) void;
extern fn nsc_profile_init() void;
extern fn nsc_profile_collect() void;
extern fn nsc_profile_generate_mirror([*]const u8, usize, *[*]const u8, *usize) void;
extern fn nsc_profile_generate_facade([*]const u8, usize, *[*]const u8, *usize) void;

const Result = struct {
    output: []const u8,
    diagnostics: []const struct { path: []const u8, message: []const u8 },
};
fn panicSink(_: ?*anyopaque, message: [*]const u8, len: usize, _: u64) callconv(.c) void {
    std.debug.print("corewire: core projection trapped: {s}\n", .{message[0..len]});
    std.process.exit(1);
}
pub fn emit(arena: std.mem.Allocator, sidecar: sidecar_mod.Sidecar, projection: enum { mirror, facade }, diags: *sidecar_mod.Diagnostics) error{ Refused, OutOfMemory }![]const u8 {
    // Hex identities and version spellings remain exact even outside the
    // JavaScript-number range. The reader's normalized structural value
    // supplies defaults and complete TypeRef/Payload facts.
    const input = try std.json.Stringify.valueAlloc(arena, .{
        .sidecar = sidecar,
        .build_id_hex = try std.fmt.allocPrint(arena, "{x:0>16}", .{sidecar.build_id}),
        .model_fingerprint_hex = try std.fmt.allocPrint(arena, "{x:0>16}", .{sidecar.model_fingerprint}),
        .wire_text = try std.fmt.allocPrint(arena, "{d}", .{sidecar.wire_version}),
        .abi_text = try std.fmt.allocPrint(arena, "{d}", .{sidecar.abi_version}),
        .snapshot_text = try std.fmt.allocPrint(arena, "{d}", .{sidecar.abi.snapshot_format}),
    }, .{});
    nsc_profile_set_panic_sink(panicSink, null);
    nsc_profile_init();
    defer nsc_profile_collect();
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    switch (projection) {
        .mirror => nsc_profile_generate_mirror(input.ptr, input.len, &ptr, &len),
        .facade => nsc_profile_generate_facade(input.ptr, input.len, &ptr, &len),
    }
    const result = std.json.parseFromSliceLeaky(Result, arena, ptr[0..len], .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic("corewire: malformed compiled core projection result"),
    };
    for (result.diagnostics) |diagnostic| diags.flag(diagnostic.path, "{s}", .{diagnostic.message});
    if (diags.hasErrors()) return error.Refused;
    return result.output;
}

test "complete projection outputs remain owned across alternating collect and init" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const with_origin = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"name\": \"Model\", \"fields\": [", "\"name\": \"Model\", \"origin\": \"core.ts\", \"fields\": [");
    const source = try std.mem.replaceOwned(u8, arena, with_origin, "\"name\": \"label_set\", \"payload\": {\"kind\": \"bytes\"}", "\"name\": \"label_set\", \"member\": \"body\", \"payload\": {\"kind\": \"bytes\"}");
    const sidecar = try sidecar_mod.read(arena, source, &diags);
    const mirror = try emit(arena, sidecar, .mirror, &diags);
    const facade = try emit(arena, sidecar, .facade, &diags);
    const mirror_copy = try arena.dupe(u8, mirror);
    const facade_copy = try arena.dupe(u8, facade);
    for (0..4) |_| {
        _ = try emit(arena, sidecar, .facade, &diags);
        _ = try emit(arena, sidecar, .mirror, &diags);
        try std.testing.expectEqualStrings(mirror_copy, mirror);
        try std.testing.expectEqualStrings(facade_copy, facade);
    }
    try std.testing.expect(std.mem.indexOf(u8, mirror, "sidecar_build_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, facade, "nscfDecodeSnapshotModel") != null);
}
