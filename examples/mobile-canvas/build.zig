const std = @import("std");
const zero_native = @import("zero_native");

pub fn build(b: *std.Build) void {
    zero_native.addMobileLib(b, b.dependency("zero_native", .{}), .{ .name = "mobile-canvas" });
}
