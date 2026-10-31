// The optional host-built embed archive uses the same compiled app core.
const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const mobile = b.option(bool, "mobile", "Expose the mobile embed archive on this host") orelse false;
    native_sdk.addApp(b, b.dependency("native_sdk", .{}), .{ .name = "ui-inbox", .mobile_lib = mobile });
}
