//! Owned-byte boundary to the scriptc-compiled service projections.
const std = @import("std");
const PanicSink = *const fn (?*anyopaque, [*]const u8, usize, u64) callconv(.c) void;
extern fn nsc_profile_set_panic_sink(PanicSink, ?*anyopaque) void;
extern fn nsc_profile_init() void;
extern fn nsc_profile_collect() void;
extern fn nsc_profile_validate_services([*]const u8, usize, *[*]const u8, *usize) void;
extern fn nsc_profile_generate_services([*]const u8, usize, [*]const u8, usize, [*]const u8, usize, *[*]const u8, *usize) void;

fn panicSink(_: ?*anyopaque, message: [*]const u8, len: usize, _: u64) callconv(.c) void {
    std.debug.print("corewire: service projection trapped: {s}\n", .{message[0..len]});
    std.process.exit(1);
}

pub fn validate(arena: std.mem.Allocator, contract: anytype, writer: *std.Io.Writer) error{ InvalidContract, OutOfMemory, WriteFailed }!void {
    const basenames = try arena.alloc([]const u8, contract.operations.len);
    for (contract.operations, 0..) |op, index| basenames[index] = std.fs.path.basename(op.module);
    // Paths are OS facts and i64 spellings must remain exact even beyond
    // JavaScript's safe-integer range. The policy receives both explicitly.
    const input = try std.json.Stringify.valueAlloc(arena, .{
        .contract = contract,
        .basenames = basenames,
        .format_text = try std.fmt.allocPrint(arena, "{d}", .{contract.format}),
        .protocol_text = try std.fmt.allocPrint(arena, "{d}", .{contract.protocol_version}),
    }, .{});
    nsc_profile_set_panic_sink(panicSink, null);
    nsc_profile_init();
    defer nsc_profile_collect();
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    nsc_profile_validate_services(input.ptr, input.len, &ptr, &len);
    // Copy while the result arena is live; writer buffers may retain bytes.
    const diagnostic = try arena.dupe(u8, ptr[0..len]);
    if (diagnostic.len != 0) {
        try writer.writeAll(diagnostic);
        return error.InvalidContract;
    }
}

pub fn generate(arena: std.mem.Allocator, input: []const u8, projection: []const u8, optimization: []const u8) error{OutOfMemory}![]const u8 {
    nsc_profile_set_panic_sink(panicSink, null);
    nsc_profile_init();
    defer nsc_profile_collect();
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    nsc_profile_generate_services(input.ptr, input.len, projection.ptr, projection.len, optimization.ptr, optimization.len, &ptr, &len);
    return arena.dupe(u8, ptr[0..len]);
}
