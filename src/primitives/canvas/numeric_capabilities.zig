const std = @import("std");

/// Native f32 extrema have target-specific signs for opposite zero operands.
/// Runtime probes expose only that numeric capability, never render decisions.
pub fn numericFlags() u8 {
    var zeros = [_]f32{ -0.0, 0.0 };
    std.mem.doNotOptimizeAway(&zeros);
    const values = [_]f32{ @min(zeros[0], zeros[1]), @min(zeros[1], zeros[0]), @max(zeros[0], zeros[1]), @max(zeros[1], zeros[0]) };
    var flags: u8 = 0;
    for (values, 0..) |v, i| if (@as(u32, @bitCast(v)) == 0x80000000) {
        flags |= @as(u8, 1) << @intCast(i);
    };
    return flags;
}
