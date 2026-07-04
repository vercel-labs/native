const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    native_sdk.addApp(b, b.dependency("native_sdk", .{}), .{ .name = "system-monitor" });
}
