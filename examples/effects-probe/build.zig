const std = @import("std");
const zero_native = @import("zero_native");

pub fn build(b: *std.Build) void {
    zero_native.addApp(b, b.dependency("zero_native", .{}), .{ .name = "effects-probe" });
}
