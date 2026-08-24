//! Phase-1 Swift toolchain fixture: the ordinary Native SDK app/test
//! artifacts both consume one app-owned Swift source. The app executable is
//! ReleaseFast by default while its tests are Debug, proving the helper's two
//! independently optimized Swift compiles without introducing Xcode project
//! state or a bundled helper/dylib.
const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("native_sdk", .{});
    const artifacts = native_sdk.addAppArtifacts(b, dep, .{
        .name = "swift-toolchain-proof",
        // The one app-level floor must reach both Zig final links and Swift.
        .macos_minimum = .{ .major = 12 },
    });
    native_sdk.addSwiftAppSources(b, artifacts, .{
        .sources = &.{b.path("src/NativeView.swift")},
        .module_name = "NativeViewHost",
        // AVFoundation exercises a Swift overlay outside the original
        // SwiftUI/AppKit closure; its async property API requires macOS 12.
        .frameworks = &.{ "SwiftUI", "AppKit", "Foundation", "AVFoundation" },
    });
    // `addAppArtifacts`' test step normally need not build the app binary.
    // This proof's whole purpose is to link both independently optimized
    // artifacts, so make the installed ReleaseFast executable part of its test
    // gate as well; CI smoke-runs that exact zig-out/bin artifact next.
    if (b.top_level_steps.get("test")) |test_step| {
        test_step.step.dependOn(&artifacts.install.step);
    }

    // Reproducible ReleaseFast package/sign gate for Phase 1. The standard
    // package step remains available; this focused step opts into ad-hoc
    // signing and lets codesign's strict verifier inspect the finished app.
    const package = b.addRunArtifact(dep.artifact("native"));
    package.setEnvironmentVariable("NATIVE_SDK_PATH", dep.builder.pathFromRoot("."));
    package.addArgs(&.{
        "package",
        "--target",
        "macos",
        "--manifest",
        "app.zon",
        "--output",
        "zig-out/package/swift-toolchain-proof.app",
        "--binary",
    });
    package.addFileArg(artifacts.exe.getEmittedBin());
    package.addArgs(&.{
        "--optimize",
        "ReleaseFast",
        "--web-layer",
        "exclude",
        "--web-engine",
        "system",
        "--signing",
        "adhoc",
    });
    package.has_side_effects = true;
    const signed_package = b.step("signed-package", "Build and ad-hoc sign the ReleaseFast Swift toolchain proof app");
    signed_package.dependOn(&package.step);
}
