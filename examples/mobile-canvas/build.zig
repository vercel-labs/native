// This example owns its build: its only product is the mobile embed static library (`zig build lib` via addMobileLib), not the desktop app the generated graph builds.
const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    native_sdk.addMobileLib(b, b.dependency("native_sdk", .{}), .{
        .name = "mobile-canvas",
        // The example does not use the store, but this option gives the SDK
        // gate a real mobile artifact that exercises capability-selected
        // SQLite linkage and the data-root host lifecycle.
        .store_capability = b.option(bool, "store", "Link the Tier-2 record store") orelse false,
        .relational_capability = b.option(bool, "sqlite", "Link the Tier-3 relational database") orelse false,
    });
}
