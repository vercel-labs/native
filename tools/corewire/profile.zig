//! C ABI adapter for the scriptc-compiled profile generator. Policy, export
//! signatures, validation of attestations, and JSON emission live in TypeScript.
const std = @import("std");
const sidecar_mod = @import("sidecar.zig");

pub const Error = error{ Refused, OutOfMemory };
pub const default_entry = "core_facade.ts";

const PanicSink = *const fn (?*anyopaque, [*]const u8, usize, u64) callconv(.c) void;
extern fn nsc_profile_set_panic_sink(PanicSink, ?*anyopaque) void;
extern fn nsc_profile_init() void;
extern fn nsc_profile_collect() void;
extern fn nsc_profile_generate([*]const u8, usize, [*]const u8, usize, [*]const u8, usize, *[*]const u8, *usize) void;

fn panicSink(_: ?*anyopaque, message: [*]const u8, len: usize, _: u64) callconv(.c) void {
    std.debug.print("corewire: profile generator trapped: {s}\n", .{message[0..len]});
    std.process.exit(1);
}

pub fn emitProfile(arena: std.mem.Allocator, sidecar: sidecar_mod.Sidecar, entry: []const u8, optimization: ?[]const u8, diags: *sidecar_mod.Diagnostics) Error![]const u8 {
    if (!std.unicode.utf8ValidateSlice(entry)) return error.Refused;
    if (diags.hasErrors()) return error.Refused;
    // Use the already validated and projected facts, including --f64-slot
    // demotions. Never reread the original sidecar across this boundary.
    const input = try std.json.Stringify.valueAlloc(arena, .{
        .deterministic = sidecar.deterministic,
        .async_free = sidecar.async_free,
        .wire_version = sidecar.wire_version,
        .abi_version = sidecar.abi_version,
        .model = sidecar.model,
        .msg = .{ .name = sidecar.msg.name },
        .has_subscriptions = sidecar.has_subscriptions,
        .abi = sidecar.abi,
        .integer_slots = sidecar.integer_slots,
    }, .{});
    const opt = optimization orelse "";
    nsc_profile_set_panic_sink(panicSink, null);
    nsc_profile_init();
    defer nsc_profile_collect();
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    nsc_profile_generate(input.ptr, input.len, entry.ptr, entry.len, opt.ptr, opt.len, &ptr, &len);
    const Result = struct {
        output: []const u8,
        diagnostics: []const struct { path: []const u8, message: []const u8 },
    };
    // The result arena belongs to scriptc. Copy all strings before collect
    // invalidates it, so callers can retain results across repeated calls.
    const result = std.json.parseFromSliceLeaky(Result, arena, ptr[0..len], .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic("corewire: invalid response from the compiled profile generator"),
    };
    for (result.diagnostics) |diag| diags.flag(diag.path, "{s}", .{diag.message});
    if (diags.hasErrors()) return error.Refused;
    return result.output;
}
