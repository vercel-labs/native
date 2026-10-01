//! A separate process proves compiler-detected traps reach the host panic
//! sink. Exiting from the sink avoids an intentional OS crash dialog in CI.
const std = @import("std");
const core = @import("shim_core");
const abi = @import("core_abi").Bindings("nsc_core_");

var cookie: u32 = 0x51deca7;

fn panicSink(context: ?*anyopaque, message: [*]const u8, length: usize, _: u64) callconv(.c) void {
    if (context != @as(?*anyopaque, @ptrCast(&cookie)) or length == 0) std.process.exit(1);
    std.debug.print("compiled-core panic sink: {s}\n", .{message[0..length]});
    std.process.exit(73);
}

pub fn main() !void {
    _ = core.initialModel();
    abi.set_panic_sink(panicSink, &cookie);
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    // The fixture has fewer than 255 Msg arms. An undeclared wire tag must
    // reach the detected-trap sink, never silently update or return success.
    abi.dispatch_void(255, &out, &len);
    return error.TrapDidNotReachPanicSink;
}
