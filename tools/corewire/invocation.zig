//! Owned-byte adapters for compiled invocation rules and decoded OS facts.
const std = @import("std");
const sidecar_mod = @import("sidecar.zig");
const PanicSink = *const fn (?*anyopaque, [*]const u8, usize, u64) callconv(.c) void;
extern fn nsc_profile_set_panic_sink(PanicSink, ?*anyopaque) void;
extern fn nsc_profile_init() void;
extern fn nsc_profile_collect() void;
extern fn nsc_profile_invocation_plan([*]const u8, usize, *[*]const u8, *usize) void;
extern fn nsc_profile_invocation_aliases([*]const u8, usize, *[*]const u8, *usize) void;
extern fn nsc_profile_core_invocation([*]const u8, usize, *[*]const u8, *usize) void;
extern fn nsc_profile_effective_sidecar([*]const u8, usize, *[*]const u8, *usize) void;

pub const Output = struct { kind: enum { mirror, facade, profile, effective, host, registry, client, inproc_main, inproc_profile }, flag: []const u8, path_index: usize };
pub const Plan = struct {
    mode: enum { core, service },
    input: ?usize,
    outputs: []const Output,
    check_only: bool,
    optimization: ?usize,
    slots: []const usize,
    @"error": []const u8,
    exit_code: u8,
};
pub const CoreResult = struct {
    mirror: []const u8,
    facade: []const u8,
    profile: []const u8,
    effective: []const u8,
    diagnostics: []const struct { path: []const u8, message: []const u8 },
    @"error": []const u8,
    exit_code: u8,
};
pub const Entry = struct {
    text: []const u8 = "core_facade.ts",
    utf8: bool = true,
    unrelated: bool = false,
    facade_path: []const u8 = "",
    profile_directory: []const u8 = "",
    bytes: []const u8 = "core_facade.ts",
};
const Operation = enum { plan, aliases, core, effective };
fn panicSink(_: ?*anyopaque, message: [*]const u8, len: usize, _: u64) callconv(.c) void {
    std.debug.print("corewire: invocation policy trapped: {s}\n", .{message[0..len]});
    std.process.exit(1);
}
fn call(arena: std.mem.Allocator, operation: Operation, input: []const u8) error{OutOfMemory}![]const u8 {
    nsc_profile_set_panic_sink(panicSink, null);
    nsc_profile_init();
    defer nsc_profile_collect();
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    switch (operation) {
        .plan => nsc_profile_invocation_plan(input.ptr, input.len, &ptr, &len),
        .aliases => nsc_profile_invocation_aliases(input.ptr, input.len, &ptr, &len),
        .core => nsc_profile_core_invocation(input.ptr, input.len, &ptr, &len),
        .effective => nsc_profile_effective_sidecar(input.ptr, input.len, &ptr, &len),
    }
    return arena.dupe(u8, ptr[0..len]);
}
fn decode(comptime T: type, arena: std.mem.Allocator, source: []const u8) error{OutOfMemory}!T {
    return std.json.parseFromSliceLeaky(T, arena, source, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic("corewire: malformed compiled invocation result"),
    };
}
// Byte arrays preserve arguments/path spellings that are not UTF-8. They
// are transported as facts, never converted through JavaScript strings.
fn rawJson(arena: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    var array: std.json.Array = .init(arena);
    for (bytes) |byte| try array.append(.{ .integer = byte });
    return .{ .array = array };
}
fn rawList(arena: std.mem.Allocator, values: []const []const u8) ![]const std.json.Value {
    const out = try arena.alloc(std.json.Value, values.len);
    for (values, 0..) |value, index| out[index] = try rawJson(arena, value);
    return out;
}
pub fn plan(arena: std.mem.Allocator, args: []const []const u8) !Plan {
    const input = try std.json.Stringify.valueAlloc(arena, try rawList(arena, args), .{});
    return decode(Plan, arena, try call(arena, .plan, input));
}
pub fn aliases(arena: std.mem.Allocator, input: []const u8, paths: []const []const u8, identities: []const []const bool) ![]const u8 {
    const facts = try std.json.Stringify.valueAlloc(arena, .{
        .input = try rawJson(arena, input),
        .paths = try rawList(arena, paths),
        .identities = identities,
    }, .{});
    return decode([]const u8, arena, try call(arena, .aliases, facts));
}
pub fn canonicalJson(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    // Scalar JSON spellings are decoder facts: f64 shortest formatting,
    // full-width integers and unknown additive fields never roundtrip
    // through a JavaScript number. TypeScript selects and edits the tree.
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{});
    return std.json.Stringify.valueAlloc(arena, root, .{ .whitespace = .indent_2 });
}
pub fn effective(arena: std.mem.Allocator, source: []const u8, slots: []const []const u8) ![]const u8 {
    if (slots.len == 0) return source;
    const facts = try std.json.Stringify.valueAlloc(arena, .{
        .canonical_source = try canonicalJson(arena, source),
        .slots = try rawList(arena, slots),
    }, .{});
    return call(arena, .effective, facts);
}
pub fn core(arena: std.mem.Allocator, sidecar: sidecar_mod.Sidecar, invocation: Plan, args: []const []const u8, entry: Entry, source: []const u8) !CoreResult {
    const slots = try arena.alloc([]const u8, invocation.slots.len);
    for (invocation.slots, 0..) |index, at| slots[at] = args[index];
    const outputs = try arena.alloc([]const u8, invocation.outputs.len);
    var need_effective = false;
    for (invocation.outputs, 0..) |out, at| {
        outputs[at] = @tagName(out.kind);
        if (out.kind == .effective) need_effective = true;
    }
    const optimization = if (invocation.optimization) |index| args[index] else null;
    const input = try std.json.Stringify.valueAlloc(arena, .{
        .sidecar = sidecar,
        .build_id_hex = try std.fmt.allocPrint(arena, "{x:0>16}", .{sidecar.build_id}),
        .model_fingerprint_hex = try std.fmt.allocPrint(arena, "{x:0>16}", .{sidecar.model_fingerprint}),
        .wire_text = try std.fmt.allocPrint(arena, "{d}", .{sidecar.wire_version}),
        .abi_text = try std.fmt.allocPrint(arena, "{d}", .{sidecar.abi_version}),
        .snapshot_text = try std.fmt.allocPrint(arena, "{d}", .{sidecar.abi.snapshot_format}),
        .slots = try rawList(arena, slots),
        .outputs = outputs,
        .check_only = invocation.check_only,
        .optimization = if (optimization) |value| if (std.unicode.utf8ValidateSlice(value)) value else "invalid" else null,
        .entry = entry.text,
        .entry_utf8 = entry.utf8,
        .entry_unrelated = entry.unrelated,
        .facade_path = try rawJson(arena, entry.facade_path),
        .profile_directory = try rawJson(arena, entry.profile_directory),
        .entry_bytes = try rawJson(arena, entry.bytes),
        .source = if (need_effective) source else "",
        .canonical_source = if (need_effective and slots.len != 0) try canonicalJson(arena, source) else "",
    }, .{});
    return decode(CoreResult, arena, try call(arena, .core, input));
}
