// This example owns its build: its only product is the mobile embed static library (`zig build lib` via addMobileLib), not the desktop app the generated graph builds.
const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    native_sdk.addMobileLib(b, b.dependency("native_sdk", .{}), .{ .name = "mobile-canvas" });
}
