// This example owns its build: the emulator core (libghostty-vt) is a
// third-party Zig module the generated app graph does not provide, so the
// app and test modules import it here on top of the standard app build.
const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{ .name = "terminal" });
    const app_module = artifacts.exe.root_module;
    const ghostty = b.dependency("ghostty", .{
        .target = app_module.resolved_target.?,
        .optimize = app_module.optimize.?,
        // Keep the vt module pure Zig: the SIMD paths pull vendored C++
        // dependencies the terminal example does not need.
        .simd = false,
        // Only the vt MODULE is consumed: ghostty's own macOS app and
        // xcframework artifacts default ON for Darwin hosts and their
        // CONFIGURE step resolves the iOS libc — which aborts on a
        // machine with only the command-line tools. Neither artifact is
        // wanted here on any host.
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
    });
    const vt = ghostty.module("ghostty-vt");
    app_module.addImport("ghostty-vt", vt);
    if (artifacts.tests.root_module != app_module) {
        artifacts.tests.root_module.addImport("ghostty-vt", vt);
    }
}
