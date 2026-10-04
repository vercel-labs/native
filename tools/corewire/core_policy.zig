//! Owned result boundary to the compiled core-contract policy.
const std = @import("std");
const PanicSink = *const fn (?*anyopaque, [*]const u8, usize, u64) callconv(.c) void;
extern fn nsc_profile_set_panic_sink(PanicSink, ?*anyopaque) void;
extern fn nsc_profile_init() void;
extern fn nsc_profile_collect() void;
extern fn nsc_profile_core_policy([*]const u8, usize, [*]const u8, usize, *[*]const u8, *usize) void;

pub const Result = struct {
    diagnostics: []const struct { path: []const u8, message: []const u8 },
    inlined: []const []const u8,
    flattened: []const []const u8,
    node_stored: []const []const u8,
};

fn panicSink(_: ?*anyopaque, message: [*]const u8, len: usize, _: u64) callconv(.c) void {
    std.debug.print("corewire: core contract policy trapped: {s}\n", .{message[0..len]});
    std.process.exit(1);
}

pub fn evaluate(arena: std.mem.Allocator, sidecar: anytype, phase: []const u8) error{OutOfMemory}!Result {
    // A native i64 diagnostic must retain its exact spelling beyond 2^53.
    // TypeRef/Payload serializers carry the decoder's complete shape.
    const input = try std.json.Stringify.valueAlloc(arena, .{
        .sidecar = sidecar,
        .wire_text = try std.fmt.allocPrint(arena, "{d}", .{sidecar.wire_version}),
        .abi_text = try std.fmt.allocPrint(arena, "{d}", .{sidecar.abi_version}),
        .snapshot_text = try std.fmt.allocPrint(arena, "{d}", .{sidecar.abi.snapshot_format}),
    }, .{});
    nsc_profile_set_panic_sink(panicSink, null);
    nsc_profile_init();
    defer nsc_profile_collect();
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    nsc_profile_core_policy(input.ptr, input.len, phase.ptr, phase.len, &ptr, &len);
    // Own every nested string before collect, including plan names and
    // diagnostics retained by the caller across subsequent init cycles.
    return std.json.parseFromSliceLeaky(Result, arena, ptr[0..len], .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic("corewire: malformed compiled core policy result"),
    };
}

pub fn apply(arena: std.mem.Allocator, sidecar: anytype, phase: []const u8, diags: anytype) error{OutOfMemory}!Result {
    const result = try evaluate(arena, sidecar, phase);
    for (result.diagnostics) |diagnostic| diags.flag(diagnostic.path, "{s}", .{diagnostic.message});
    return result;
}
