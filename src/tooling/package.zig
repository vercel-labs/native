const std = @import("std");
const assets_tool = @import("assets.zig");
const cef = @import("cef.zig");
const codesign = @import("codesign.zig");
const diagnostics = @import("diagnostics");
const manifest_tool = @import("manifest.zig");
const web_engine_tool = @import("web_engine.zig");

pub const PackageTarget = enum {
    macos,
    windows,
    linux,
    ios,
    android,

    pub fn parse(value: []const u8) ?PackageTarget {
        inline for (@typeInfo(PackageTarget).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const SigningMode = enum {
    none,
    adhoc,
    identity,

    pub fn parse(value: []const u8) ?SigningMode {
        if (std.mem.eql(u8, value, "none")) return .none;
        if (std.mem.eql(u8, value, "adhoc") or std.mem.eql(u8, value, "ad-hoc")) return .adhoc;
        if (std.mem.eql(u8, value, "identity")) return .identity;
        return null;
    }
};

pub const WebEngine = web_engine_tool.Engine;

pub const SigningConfig = struct {
    mode: SigningMode = .none,
    identity: ?[]const u8 = null,
    entitlements: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    team_id: ?[]const u8 = null,
};

pub const PackageOptions = struct {
    metadata: manifest_tool.Metadata,
    target: PackageTarget = .macos,
    optimize: []const u8 = "Debug",
    output_path: []const u8,
    binary_path: ?[]const u8 = null,
    assets_dir: []const u8 = "assets",
    frontend: ?manifest_tool.FrontendMetadata = null,
    web_engine: WebEngine = .system,
    cef_dir: []const u8 = web_engine_tool.default_cef_dir,
    signing: SigningConfig = .{},
    archive: bool = false,
};

pub const PackageStats = struct {
    path: []const u8,
    artifact_name: []const u8 = "",
    target: PackageTarget = .macos,
    signing_mode: SigningMode = .none,
    asset_count: usize = 0,
    web_engine: WebEngine = .system,
    archive_path: ?[]const u8 = null,
};

pub fn artifactName(buffer: []u8, metadata: manifest_tool.Metadata, target: PackageTarget, optimize: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}-{s}-{s}-{s}{s}", .{
        metadata.name,
        metadata.version,
        @tagName(target),
        optimize,
        artifactSuffix(target),
    });
}

pub fn createPackage(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !PackageStats {
    var stats = switch (options.target) {
        .macos => try createMacosApp(allocator, io, options),
        .windows, .linux => try createDesktopArtifact(allocator, io, options),
        .ios => try createIosArtifact(allocator, io, options),
        .android => try createAndroidArtifact(allocator, io, options),
    };
    if (options.archive) {
        const archive_path = try createArchive(allocator, io, options);
        if (archive_path) |path| {
            stats.archive_path = path;
        }
    }
    return stats;
}

pub fn printDiagnostic(stats: PackageStats) void {
    var buffer: [256]u8 = undefined;
    var message_buffer: [192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    diagnostics.formatShort(.{
        .severity = .info,
        .code = diagnostics.code("package", "created"),
        .message = std.fmt.bufPrint(&message_buffer, "created {s} artifact at {s}", .{ @tagName(stats.target), stats.path }) catch "created package",
    }, &writer) catch return;
    std.debug.print("{s}\n", .{writer.buffered()});
    if (stats.archive_path) |archive| {
        std.debug.print("  archive: {s}\n", .{archive});
    }
}

pub fn createLocalPackage(io: std.Io, output_path: []const u8) !PackageStats {
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.zero_native.local",
        .name = "zero-native-local",
        .version = "0.1.0",
    };
    return createMacosApp(std.heap.page_allocator, io, .{
        .metadata = metadata,
        .output_path = output_path,
        .binary_path = null,
    });
}

pub fn createMacosApp(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !PackageStats {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, options.output_path);
    var package_dir = try cwd.openDir(io, options.output_path, .{});
    defer package_dir.close(io);
    try package_dir.createDirPath(io, "Contents/MacOS");
    try package_dir.createDirPath(io, "Contents/Resources");

    const executable_name = std.fs.path.basename(options.metadata.name);
    if (options.binary_path) |binary_path| {
        const executable_subpath = try std.fmt.allocPrint(allocator, "Contents/MacOS/{s}", .{executable_name});
        defer allocator.free(executable_subpath);
        try copyFileToDir(allocator, io, package_dir, binary_path, executable_subpath);
    } else {
        try writeFile(package_dir, io, "Contents/MacOS/README.txt", "No app binary was supplied for this local package.\n");
    }

    const info_plist = try macosInfoPlist(allocator, options.metadata, executable_name);
    defer allocator.free(info_plist);
    try writeFile(package_dir, io, "Contents/Info.plist", info_plist);
    try writeFile(package_dir, io, "Contents/PkgInfo", "APPL????");
    try writeFile(package_dir, io, "Contents/Resources/README.txt", "Unsigned local zero-native macOS app bundle.\n");
    const assets_output = try assetOutputPath(allocator, options.output_path, "Contents/Resources", options);
    defer allocator.free(assets_output);
    const bundle_stats = try assets_tool.bundle(allocator, io, options.assets_dir, assets_output);
    try copyMacosIcon(allocator, io, package_dir, options);
    try writeReport(allocator, package_dir, io, "Contents/Resources/package-manifest.zon", options, executable_name, bundle_stats.asset_count);
    if (options.web_engine == .chromium) {
        try cef.ensureLayout(io, options.cef_dir);
        try copyMacosCefRuntime(allocator, io, package_dir, options.cef_dir);
    }
    try runSigning(allocator, io, package_dir, options);

    return .{
        .path = options.output_path,
        .artifact_name = std.fs.path.basename(options.output_path),
        .target = .macos,
        .signing_mode = options.signing.mode,
        .asset_count = bundle_stats.asset_count,
        .web_engine = options.web_engine,
    };
}

pub fn createIosSkeleton(io: std.Io, output_path: []const u8) !PackageStats {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, output_path);
    var dir = try cwd.openDir(io, output_path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "zero-nativeHost");
    try writeFile(dir, io, "README.md", iosReadme());
    try writeFile(dir, io, "Info.plist", iosInfoPlist());
    try writeFile(dir, io, "zero-nativeHost/ZeroNativeHostViewController.swift", iosViewController());
    try writeFile(dir, io, "zero-nativeHost/zero_native.h", embedHeader());
    return .{ .path = output_path, .target = .ios };
}

pub fn createAndroidSkeleton(io: std.Io, output_path: []const u8) !PackageStats {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, output_path);
    var dir = try cwd.openDir(io, output_path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "app/src/main/java/dev/zero_native/examples/android");
    try dir.createDirPath(io, "app/src/main/cpp");
    try dir.createDirPath(io, "app/src/main/res/values");
    try writeFile(dir, io, "README.md", androidReadme());
    try writeFile(dir, io, "settings.gradle", androidSettingsGradle());
    try writeFile(dir, io, "build.gradle", androidRootBuildGradle());
    try writeFile(dir, io, "app/build.gradle", androidAppBuildGradle());
    try writeFile(dir, io, "app/src/main/AndroidManifest.xml", androidManifest());
    try writeFile(dir, io, "app/src/main/res/values/styles.xml", androidStyles());
    try writeFile(dir, io, "app/src/main/java/dev/zero_native/examples/android/MainActivity.kt", androidActivity());
    try writeFile(dir, io, "app/src/main/cpp/CMakeLists.txt", androidCMakeLists());
    try writeFile(dir, io, "app/src/main/cpp/zero_native_jni.c", androidJni());
    try writeFile(dir, io, "app/src/main/cpp/zero_native.h", embedHeader());
    return .{ .path = output_path, .target = .android };
}

fn createDesktopArtifact(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !PackageStats {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, options.output_path);
    var dir = try cwd.openDir(io, options.output_path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "bin");
    try dir.createDirPath(io, "resources");

    const executable_name = if (options.target == .windows)
        try std.fmt.allocPrint(allocator, "{s}.exe", .{options.metadata.name})
    else
        try allocator.dupe(u8, options.metadata.name);
    defer allocator.free(executable_name);

    if (options.binary_path) |binary_path| {
        const binary_subpath = try std.fmt.allocPrint(allocator, "bin/{s}", .{executable_name});
        defer allocator.free(binary_subpath);
        try copyFileToDir(allocator, io, dir, binary_path, binary_subpath);
    } else {
        try writeFile(dir, io, "bin/README.txt", "Build the app binary separately and place it here for this target.\n");
    }

    const assets_output = try assetOutputPath(allocator, options.output_path, "resources", options);
    defer allocator.free(assets_output);
    const bundle_stats = try assets_tool.bundle(allocator, io, options.assets_dir, assets_output);
    try writeFile(dir, io, "README.txt", artifactReadme(options.target));
    if (options.target == .linux) {
        try dir.createDirPath(io, "share/applications");
        try dir.createDirPath(io, "share/icons");
        const desktop_entry = try linuxDesktopEntry(allocator, options.metadata);
        defer allocator.free(desktop_entry);
        const desktop_path = try std.fmt.allocPrint(allocator, "share/applications/{s}.desktop", .{options.metadata.name});
        defer allocator.free(desktop_path);
        try writeFile(dir, io, desktop_path, desktop_entry);
        if (options.metadata.icons.len > 0) {
            copyFileToDir(allocator, io, dir, options.metadata.icons[0], "share/icons/app-icon.png") catch {};
        }
    }
    if (options.web_engine == .chromium) {
        const cef_platform = cefPlatformForTarget(options.target) orelse return error.UnsupportedWebEngine;
        try cef.ensureLayoutFor(io, cef_platform, options.cef_dir);
        try copyDesktopCefRuntime(allocator, io, dir, options.target, options.cef_dir);
    }
    try writeReport(allocator, dir, io, "package-manifest.zon", options, executable_name, bundle_stats.asset_count);
    return .{ .path = options.output_path, .artifact_name = std.fs.path.basename(options.output_path), .target = options.target, .asset_count = bundle_stats.asset_count, .web_engine = options.web_engine };
}

fn createIosArtifact(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !PackageStats {
    _ = try createIosSkeleton(io, options.output_path);
    var dir = try std.Io.Dir.cwd().openDir(io, options.output_path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "Libraries");
    if (options.binary_path) |binary_path| try copyFileToDir(allocator, io, dir, binary_path, "Libraries/libzero-native.a");
    try writeReport(allocator, dir, io, "package-manifest.zon", options, "libzero-native.a", 0);
    return .{ .path = options.output_path, .artifact_name = std.fs.path.basename(options.output_path), .target = .ios, .web_engine = options.web_engine };
}

fn createAndroidArtifact(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !PackageStats {
    _ = try createAndroidSkeleton(io, options.output_path);
    var dir = try std.Io.Dir.cwd().openDir(io, options.output_path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "app/src/main/cpp/lib");
    if (options.binary_path) |binary_path| try copyFileToDir(allocator, io, dir, binary_path, "app/src/main/cpp/lib/libzero-native.a");
    try writeReport(allocator, dir, io, "package-manifest.zon", options, "libzero-native.a", 0);
    return .{ .path = options.output_path, .artifact_name = std.fs.path.basename(options.output_path), .target = .android, .web_engine = options.web_engine };
}

fn writeFile(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn assetOutputPath(allocator: std.mem.Allocator, output_path: []const u8, resources_subpath: []const u8, options: PackageOptions) ![]const u8 {
    if (options.frontend) |frontend| {
        return std.fs.path.join(allocator, &.{ output_path, resources_subpath, frontend.dist });
    }
    return std.fs.path.join(allocator, &.{ output_path, resources_subpath });
}

fn macosInfoPlist(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata, executable_name: []const u8) ![]const u8 {
    const icon_name = macosIconFile(metadata);
    const bundle_id = try xmlEscapeAlloc(allocator, metadata.id);
    defer allocator.free(bundle_id);
    const name = try xmlEscapeAlloc(allocator, metadata.name);
    defer allocator.free(name);
    const display_name = try xmlEscapeAlloc(allocator, metadata.displayName());
    defer allocator.free(display_name);
    const executable = try xmlEscapeAlloc(allocator, executable_name);
    defer allocator.free(executable);
    const icon = try xmlEscapeAlloc(allocator, icon_name);
    defer allocator.free(icon);
    const version = try xmlEscapeAlloc(allocator, metadata.version);
    defer allocator.free(version);
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleName</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleDisplayName</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleExecutable</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleIconFile</key>
        \\  <string>{s}</string>
        \\  <key>CFBundlePackageType</key>
        \\  <string>APPL</string>
        \\  <key>CFBundleShortVersionString</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleVersion</key>
        \\  <string>{s}</string>
        \\</dict>
        \\</plist>
        \\
    , .{ bundle_id, name, display_name, executable, icon, version, version });
}

fn embedHeader() []const u8 {
    return
    \\#pragma once
    \\#include <stdint.h>
    \\#include <stddef.h>
    \\void *zero_native_app_create(void);
    \\void zero_native_app_destroy(void *app);
    \\void zero_native_app_start(void *app);
    \\void zero_native_app_stop(void *app);
    \\void zero_native_app_resize(void *app, float width, float height, float scale, void *surface);
    \\void zero_native_app_touch(void *app, uint64_t id, int phase, float x, float y, float pressure);
    \\void zero_native_app_frame(void *app);
    \\void zero_native_app_set_asset_root(void *app, const char *path, uintptr_t len);
    \\uintptr_t zero_native_app_last_command_count(void *app);
    \\
    ;
}

fn iosReadme() []const u8 {
    return "iOS zero-native host skeleton. Link libzero-native.a and call the functions in zero-nativeHost/zero_native.h from the view controller.\n";
}

fn iosInfoPlist() []const u8 {
    return
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.zero_native.ios</string><key>CFBundleName</key><string>zero-nativeHost</string></dict></plist>
    \\
    ;
}

fn iosViewController() []const u8 {
    return
    \\import UIKit
    \\import WebKit
    \\
    \\final class ZeroNativeHostViewController: UIViewController {
    \\    private let webView = WKWebView(frame: .zero)
    \\    override func viewDidLoad() {
    \\        super.viewDidLoad()
    \\        webView.frame = view.bounds
    \\        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    \\        view.addSubview(webView)
    \\    }
    \\}
    \\
    ;
}

fn androidReadme() []const u8 {
    return
    \\# Android Host Skeleton
    \\
    \\A minimal Android host app that embeds a zero-native static library through JNI.
    \\
    \\Copy `libzero-native.a` into `app/src/main/cpp/lib/libzero-native.a`, then build with Android Studio or Gradle.
    \\
    ;
}

fn androidSettingsGradle() []const u8 {
    return
    \\pluginManagement {
    \\    repositories {
    \\        google()
    \\        mavenCentral()
    \\        gradlePluginPortal()
    \\    }
    \\}
    \\
    \\dependencyResolutionManagement {
    \\    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    \\    repositories {
    \\        google()
    \\        mavenCentral()
    \\    }
    \\}
    \\
    \\rootProject.name = "ZeroNativeAndroidHost"
    \\include ":app"
    \\
    ;
}

fn androidRootBuildGradle() []const u8 {
    return
    \\plugins {
    \\    id "com.android.application" version "8.5.0" apply false
    \\    id "org.jetbrains.kotlin.android" version "2.0.20" apply false
    \\}
    \\
    ;
}

fn androidAppBuildGradle() []const u8 {
    return
    \\plugins {
    \\    id "com.android.application"
    \\    id "org.jetbrains.kotlin.android"
    \\}
    \\
    \\android {
    \\    namespace "dev.zero_native.examples.android"
    \\    compileSdk 35
    \\
    \\    defaultConfig {
    \\        applicationId "dev.zero_native.examples.android"
    \\        minSdk 26
    \\        targetSdk 35
    \\        versionCode 1
    \\        versionName "0.1.0"
    \\
    \\        externalNativeBuild {
    \\            cmake {
    \\                arguments "-DANDROID_STL=c++_shared"
    \\            }
    \\        }
    \\    }
    \\
    \\    externalNativeBuild {
    \\        cmake {
    \\            path "src/main/cpp/CMakeLists.txt"
    \\        }
    \\    }
    \\}
    \\
    ;
}

fn androidManifest() []const u8 {
    return
    \\<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    \\    <application
    \\        android:label="zero-native Host"
    \\        android:theme="@style/AppTheme">
    \\        <activity
    \\            android:name=".MainActivity"
    \\            android:exported="true">
    \\            <intent-filter>
    \\                <action android:name="android.intent.action.MAIN" />
    \\                <category android:name="android.intent.category.LAUNCHER" />
    \\            </intent-filter>
    \\        </activity>
    \\    </application>
    \\</manifest>
    \\
    ;
}

fn androidStyles() []const u8 {
    return
    \\<resources>
    \\    <style name="AppTheme" parent="android:style/Theme.Material.Light.NoActionBar">
    \\        <item name="android:windowLightStatusBar">true</item>
    \\        <item name="android:colorAccent">#2563EB</item>
    \\    </style>
    \\</resources>
    \\
    ;
}

fn androidActivity() []const u8 {
    return
    \\package dev.zero_native.examples.android
    \\
    \\import android.app.Activity
    \\import android.os.Bundle
    \\import android.view.MotionEvent
    \\import android.view.SurfaceHolder
    \\import android.view.SurfaceView
    \\import android.widget.FrameLayout
    \\import android.widget.TextView
    \\
    \\class MainActivity : Activity(), SurfaceHolder.Callback {
    \\    private var nativeApp: Long = 0
    \\
    \\    override fun onCreate(savedInstanceState: Bundle?) {
    \\        super.onCreate(savedInstanceState)
    \\        System.loadLibrary("zero_native_example")
    \\
    \\        val surface = SurfaceView(this)
    \\        surface.holder.addCallback(this)
    \\
    \\        val label = TextView(this).apply {
    \\            text = "zero-native Android Host"
    \\            textSize = 22f
    \\            setPadding(32, 32, 32, 32)
    \\        }
    \\
    \\        val root = FrameLayout(this)
    \\        root.addView(surface)
    \\        root.addView(label)
    \\        setContentView(root)
    \\
    \\        nativeApp = nativeCreate()
    \\        nativeStart(nativeApp)
    \\    }
    \\
    \\    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
    \\        nativeResize(nativeApp, width.toFloat(), height.toFloat(), resources.displayMetrics.density, holder.surface)
    \\        nativeFrame(nativeApp)
    \\    }
    \\
    \\    override fun surfaceCreated(holder: SurfaceHolder) = Unit
    \\
    \\    override fun surfaceDestroyed(holder: SurfaceHolder) {
    \\        nativeStop(nativeApp)
    \\    }
    \\
    \\    override fun onTouchEvent(event: MotionEvent): Boolean {
    \\        nativeTouch(nativeApp, event.getPointerId(0).toLong(), event.actionMasked, event.x, event.y, event.pressure)
    \\        nativeFrame(nativeApp)
    \\        return true
    \\    }
    \\
    \\    override fun onDestroy() {
    \\        if (nativeApp != 0L) {
    \\            nativeStop(nativeApp)
    \\            nativeDestroy(nativeApp)
    \\            nativeApp = 0
    \\        }
    \\        super.onDestroy()
    \\    }
    \\
    \\    external fun nativeCreate(): Long
    \\    external fun nativeDestroy(app: Long)
    \\    external fun nativeStart(app: Long)
    \\    external fun nativeStop(app: Long)
    \\    external fun nativeResize(app: Long, width: Float, height: Float, scale: Float, surface: Any)
    \\    external fun nativeTouch(app: Long, id: Long, phase: Int, x: Float, y: Float, pressure: Float)
    \\    external fun nativeFrame(app: Long)
    \\}
    \\
    ;
}

fn androidCMakeLists() []const u8 {
    return
    \\cmake_minimum_required(VERSION 3.22.1)
    \\
    \\project(zero_native_android_host C)
    \\
    \\add_library(zero-native STATIC IMPORTED)
    \\set_target_properties(zero-native PROPERTIES
    \\    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/lib/libzero-native.a"
    \\)
    \\
    \\add_library(zero_native_example SHARED zero_native_jni.c)
    \\target_include_directories(zero_native_example PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    \\target_link_libraries(zero_native_example zero-native android log)
    \\
    ;
}

fn androidJni() []const u8 {
    return
    \\#include <jni.h>
    \\#include <stdint.h>
    \\
    \\#include "zero_native.h"
    \\
    \\JNIEXPORT jlong JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeCreate(JNIEnv *env, jobject self) {
    \\    (void)env;
    \\    (void)self;
    \\    return (jlong)zero_native_app_create();
    \\}
    \\
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeDestroy(JNIEnv *env, jobject self, jlong app) {
    \\    (void)env;
    \\    (void)self;
    \\    zero_native_app_destroy((void *)app);
    \\}
    \\
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeStart(JNIEnv *env, jobject self, jlong app) {
    \\    (void)env;
    \\    (void)self;
    \\    zero_native_app_start((void *)app);
    \\}
    \\
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeStop(JNIEnv *env, jobject self, jlong app) {
    \\    (void)env;
    \\    (void)self;
    \\    zero_native_app_stop((void *)app);
    \\}
    \\
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeResize(JNIEnv *env, jobject self, jlong app, jfloat width, jfloat height, jfloat scale, jobject surface) {
    \\    (void)env;
    \\    (void)self;
    \\    zero_native_app_resize((void *)app, width, height, scale, surface);
    \\}
    \\
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeTouch(JNIEnv *env, jobject self, jlong app, jlong id, jint phase, jfloat x, jfloat y, jfloat pressure) {
    \\    (void)env;
    \\    (void)self;
    \\    zero_native_app_touch((void *)app, (uint64_t)id, phase, x, y, pressure);
    \\}
    \\
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeFrame(JNIEnv *env, jobject self, jlong app) {
    \\    (void)env;
    \\    (void)self;
    \\    zero_native_app_frame((void *)app);
    \\}
    \\
    ;
}

fn artifactSuffix(target: PackageTarget) []const u8 {
    return switch (target) {
        .macos => ".app",
        .windows, .linux, .ios, .android => "",
    };
}

fn artifactReadme(target: PackageTarget) []const u8 {
    return switch (target) {
        .windows => "Windows zero-native artifact directory. Installer generation is future work.\n",
        .linux => "Linux zero-native artifact directory. AppImage, Flatpak, and tarball generation are future work.\n",
        else => "zero-native artifact directory.\n",
    };
}

fn macosIconFile(metadata: manifest_tool.Metadata) []const u8 {
    if (metadata.icons.len == 0) return "AppIcon.icns";
    return std.fs.path.basename(metadata.icons[0]);
}

fn copyMacosIcon(allocator: std.mem.Allocator, io: std.Io, package_dir: std.Io.Dir, options: PackageOptions) !void {
    if (options.metadata.icons.len == 0) {
        try writeFile(package_dir, io, "Contents/Resources/AppIcon.icns", "placeholder: replace with a real macOS .icns before distributing\n");
        return;
    }
    const icon_path = options.metadata.icons[0];
    const dest = try std.fmt.allocPrint(allocator, "Contents/Resources/{s}", .{std.fs.path.basename(icon_path)});
    defer allocator.free(dest);
    const icon_bytes = readPath(allocator, io, icon_path) catch |err| switch (err) {
        error.FileNotFound => {
            try writeFile(package_dir, io, dest, "placeholder: configured app icon was not found; replace with a real macOS .icns before distributing\n");
            return;
        },
        else => return err,
    };
    defer allocator.free(icon_bytes);
    if (!isValidIcns(icon_bytes)) {
        std.debug.print("warning: {s} does not appear to be a valid .icns file; replace before distributing\n", .{icon_path});
    }
    try writeFile(package_dir, io, dest, icon_bytes);
}

fn isValidIcns(bytes: []const u8) bool {
    if (bytes.len < 8) return false;
    return std.mem.eql(u8, bytes[0..4], "icns");
}

fn xmlEscapeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            0...8, 11...12, 14...0x1f => return error.InvalidName,
            else => try out.append(allocator, ch),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn desktopEntryEscapeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |ch| {
        switch (ch) {
            0...8, 11...12, 14...0x1f => return error.InvalidName,
            '\n', '\r', '\t' => try out.append(allocator, ' '),
            else => try out.append(allocator, ch),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn zonStringAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0...8, 11...12, 14...0x1f => {
                const escaped = try std.fmt.allocPrint(allocator, "\\x{x:0>2}", .{ch});
                defer allocator.free(escaped);
                try out.appendSlice(allocator, escaped);
            },
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn copyFileToDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, source_path: []const u8, dest_subpath: []const u8) !void {
    const bytes = try readPath(allocator, io, source_path);
    defer allocator.free(bytes);
    try writeFile(dir, io, dest_subpath, bytes);
}

fn readPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(128 * 1024 * 1024));
}

fn writeReport(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, subpath: []const u8, options: PackageOptions, executable_name: []const u8, asset_count: usize) !void {
    const capabilities = try capabilityLines(allocator, options.metadata.capabilities);
    defer allocator.free(capabilities);
    const frontend = try frontendLines(allocator, options.frontend);
    defer allocator.free(frontend);
    const artifact = try zonStringAlloc(allocator, std.fs.path.basename(options.output_path));
    defer allocator.free(artifact);
    const target = try zonStringAlloc(allocator, @tagName(options.target));
    defer allocator.free(target);
    const version = try zonStringAlloc(allocator, options.metadata.version);
    defer allocator.free(version);
    const app_id = try zonStringAlloc(allocator, options.metadata.id);
    defer allocator.free(app_id);
    const executable = try zonStringAlloc(allocator, executable_name);
    defer allocator.free(executable);
    const optimize = try zonStringAlloc(allocator, options.optimize);
    defer allocator.free(optimize);
    const web_engine = try zonStringAlloc(allocator, @tagName(options.web_engine));
    defer allocator.free(web_engine);
    const signing = try zonStringAlloc(allocator, @tagName(options.signing.mode));
    defer allocator.free(signing);
    const report = try std.fmt.allocPrint(allocator,
        \\.{{
        \\  .artifact = {s},
        \\  .target = {s},
        \\  .version = {s},
        \\  .app_id = {s},
        \\  .executable = {s},
        \\  .optimize = {s},
        \\  .web_engine = {s},
        \\  .signing = {s},
        \\  .asset_count = {d},
        \\{s}
        \\  .capabilities = .{{
        \\{s}
        \\  }},
        \\}}
        \\
    , .{
        artifact,
        target,
        version,
        app_id,
        executable,
        optimize,
        web_engine,
        signing,
        asset_count,
        frontend,
        capabilities,
    });
    defer allocator.free(report);
    try writeFile(dir, io, subpath, report);
}

fn capabilityLines(allocator: std.mem.Allocator, capabilities: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (capabilities) |capability| {
        const escaped = try zonStringAlloc(allocator, capability);
        defer allocator.free(escaped);
        try out.appendSlice(allocator, "    ");
        try out.appendSlice(allocator, escaped);
        try out.appendSlice(allocator, ",\n");
    }
    return out.toOwnedSlice(allocator);
}

fn frontendLines(allocator: std.mem.Allocator, frontend: ?manifest_tool.FrontendMetadata) ![]const u8 {
    if (frontend) |config| {
        const dist = try zonStringAlloc(allocator, config.dist);
        defer allocator.free(dist);
        const entry = try zonStringAlloc(allocator, config.entry);
        defer allocator.free(entry);
        return std.fmt.allocPrint(allocator,
            \\  .frontend = .{{ .dist = {s}, .entry = {s}, .spa_fallback = {} }},
            \\
        , .{ dist, entry, config.spa_fallback });
    }
    return allocator.dupe(u8, "");
}

fn copyMacosCefRuntime(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, cef_dir: []const u8) !void {
    try app_dir.createDirPath(io, "Contents/Frameworks");
    try app_dir.createDirPath(io, "Contents/Resources/cef");

    const framework_src = try std.fs.path.join(allocator, &.{ cef_dir, "Release", "Chromium Embedded Framework.framework" });
    defer allocator.free(framework_src);
    try copyTree(allocator, io, framework_src, app_dir, "Contents/Frameworks/Chromium Embedded Framework.framework");

    const resources_src = try std.fs.path.join(allocator, &.{ cef_dir, "Resources" });
    defer allocator.free(resources_src);
    copyTree(allocator, io, resources_src, app_dir, "Contents/Resources/cef") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn copyDesktopCefRuntime(allocator: std.mem.Allocator, io: std.Io, package_dir: std.Io.Dir, target: PackageTarget, cef_dir: []const u8) !void {
    switch (target) {
        .linux, .windows => {},
        else => return error.UnsupportedWebEngine,
    }
    try package_dir.createDirPath(io, "bin");
    try package_dir.createDirPath(io, "resources/cef");

    const release_src = try std.fs.path.join(allocator, &.{ cef_dir, "Release" });
    defer allocator.free(release_src);
    try copyTree(allocator, io, release_src, package_dir, "bin");

    const resources_src = try std.fs.path.join(allocator, &.{ cef_dir, "Resources" });
    defer allocator.free(resources_src);
    copyTree(allocator, io, resources_src, package_dir, "resources/cef") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const locales_src = try std.fs.path.join(allocator, &.{ cef_dir, "locales" });
    defer allocator.free(locales_src);
    copyTree(allocator, io, locales_src, package_dir, "bin/locales") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn cefPlatformForTarget(target: PackageTarget) ?cef.Platform {
    const current = cef.Platform.current() catch null;
    return switch (target) {
        .macos => if (current) |platform| switch (platform) {
            .macosx64, .macosarm64 => platform,
            else => .macosarm64,
        } else .macosarm64,
        .linux => if (current) |platform| switch (platform) {
            .linux64, .linuxarm64 => platform,
            else => .linux64,
        } else .linux64,
        .windows => if (current) |platform| switch (platform) {
            .windows64, .windowsarm64 => platform,
            else => .windows64,
        } else .windows64,
        .ios, .android => null,
    };
}

fn copyTree(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8, dest_dir: std.Io.Dir, dest_subpath: []const u8) !void {
    var source_dir = try std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true });
    defer source_dir.close(io);
    try dest_dir.createDirPath(io, dest_subpath);

    var walker = try source_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const dest = try std.fs.path.join(allocator, &.{ dest_subpath, entry.path });
        defer allocator.free(dest);
        switch (entry.kind) {
            .directory => try dest_dir.createDirPath(io, dest),
            .file => try std.Io.Dir.copyFile(source_dir, entry.path, dest_dir, dest, io, .{ .make_path = true, .replace = true }),
            else => {},
        }
    }
}

fn runSigning(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: PackageOptions) !void {
    switch (options.signing.mode) {
        .none => try writeFile(dir, io, "Contents/Resources/signing-plan.txt", "signing=none\nunsigned local package\n"),
        .adhoc => {
            const result = codesign.signAdHoc(io, options.output_path) catch {
                try writeFile(dir, io, "Contents/Resources/signing-plan.txt", "signing=adhoc\ncodesign --sign - failed; bundle is unsigned\n");
                return;
            };
            const status = if (result.ok) "signing=adhoc\nad-hoc signed\n" else "signing=adhoc\ncodesign --sign - failed; bundle is unsigned\n";
            try writeFile(dir, io, "Contents/Resources/signing-plan.txt", status);
        },
        .identity => {
            const identity = options.signing.identity orelse {
                try writeFile(dir, io, "Contents/Resources/signing-plan.txt", "signing=identity\nno identity provided; bundle is unsigned\n");
                return;
            };
            const result = codesign.signIdentity(io, options.output_path, identity, options.signing.entitlements) catch {
                try writeFile(dir, io, "Contents/Resources/signing-plan.txt", "signing=identity\ncodesign failed; bundle is unsigned\n");
                return;
            };
            const status_text = if (result.ok)
                try std.fmt.allocPrint(allocator, "signing=identity\nsigned with {s}\n", .{identity})
            else
                try allocator.dupe(u8, "signing=identity\ncodesign failed; bundle is unsigned\n");
            defer allocator.free(status_text);
            try writeFile(dir, io, "Contents/Resources/signing-plan.txt", status_text);
        },
    }
}

fn linuxDesktopEntry(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]const u8 {
    const display_name = try desktopEntryEscapeAlloc(allocator, metadata.displayName());
    defer allocator.free(display_name);
    const executable = try desktopEntryEscapeAlloc(allocator, metadata.name);
    defer allocator.free(executable);
    return std.fmt.allocPrint(allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name={s}
        \\Exec={s}
        \\Icon=app-icon
        \\Categories=Utility;
        \\Comment={s} desktop application
        \\
    , .{ display_name, executable, display_name });
}

fn createArchive(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !?[]const u8 {
    const archive_path = try archivePath(allocator, options);
    const cmd = switch (options.target) {
        .macos => try std.fmt.allocPrint(allocator, "hdiutil create -volname \"{s}\" -srcfolder \"{s}\" -ov -format UDZO \"{s}\"", .{ options.metadata.displayName(), options.output_path, archive_path }),
        .windows => try std.fmt.allocPrint(allocator, "cd \"{s}\" && zip -r \"{s}\" .", .{ options.output_path, archive_path }),
        .linux => try std.fmt.allocPrint(allocator, "tar czf \"{s}\" -C \"{s}\" .", .{ archive_path, options.output_path }),
        .ios, .android => {
            allocator.free(archive_path);
            return null;
        },
    };
    defer allocator.free(cmd);
    const argv = [_][]const u8{ "sh", "-c", cmd };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch {
        std.debug.print("warning: archive creation failed for {s}\n", .{archive_path});
        allocator.free(archive_path);
        return null;
    };
    _ = child.wait(io) catch {
        std.debug.print("warning: archive creation failed for {s}\n", .{archive_path});
        allocator.free(archive_path);
        return null;
    };
    return archive_path;
}

pub fn archivePath(allocator: std.mem.Allocator, options: PackageOptions) ![]const u8 {
    const dir = std.fs.path.dirname(options.output_path) orelse ".";
    return std.fmt.allocPrint(allocator, "{s}/{s}-{s}-{s}-{s}{s}", .{
        dir,
        options.metadata.name,
        options.metadata.version,
        @tagName(options.target),
        options.optimize,
        archiveSuffix(options.target),
    });
}

fn archiveSuffix(target: PackageTarget) []const u8 {
    return switch (target) {
        .macos => ".dmg",
        .windows => ".zip",
        .linux => ".tar.gz",
        .ios, .android => "",
    };
}

test "archive path includes correct suffix per platform" {
    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .version = "1.2.3" };
    const macos_path = try archivePath(std.testing.allocator, .{ .metadata = metadata, .target = .macos, .output_path = "zig-out/package/demo.app" });
    defer std.testing.allocator.free(macos_path);
    try std.testing.expect(std.mem.endsWith(u8, macos_path, ".dmg"));
    const linux_path = try archivePath(std.testing.allocator, .{ .metadata = metadata, .target = .linux, .output_path = "zig-out/package/demo" });
    defer std.testing.allocator.free(linux_path);
    try std.testing.expect(std.mem.endsWith(u8, linux_path, ".tar.gz"));
    const win_path = try archivePath(std.testing.allocator, .{ .metadata = metadata, .target = .windows, .output_path = "zig-out/package/demo" });
    defer std.testing.allocator.free(win_path);
    try std.testing.expect(std.mem.endsWith(u8, win_path, ".zip"));
}

test "linux desktop entry contains app name" {
    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .display_name = "Demo App", .version = "1.2.3" };
    const entry = try linuxDesktopEntry(std.testing.allocator, metadata);
    defer std.testing.allocator.free(entry);
    try std.testing.expect(std.mem.indexOf(u8, entry, "Name=Demo App") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry, "Exec=demo") != null);
}

test "artifact names include metadata target and optimize mode" {
    var buffer: [128]u8 = undefined;
    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .version = "1.2.3" };
    try std.testing.expectEqualStrings("demo-1.2.3-macos-Debug.app", try artifactName(&buffer, metadata, .macos, "Debug"));
}

test "plist template includes identity executable and version" {
    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .display_name = "Demo App", .version = "1.2.3", .icons = &.{"assets/icon.icns"} };
    const plist = try macosInfoPlist(std.testing.allocator, metadata, "demo");
    defer std.testing.allocator.free(plist);
    try std.testing.expect(std.mem.indexOf(u8, plist, "CFBundleIdentifier") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "CFBundleDisplayName") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "dev.example.app") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "Demo App") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "icon.icns") != null);
}

test "chromium desktop packages require a matching CEF layout" {
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.demo",
        .name = "demo",
        .version = "0.1.0",
    };

    try std.testing.expectError(error.MissingLayout, createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .linux,
        .output_path = ".zig-cache/test-package-linux-chromium",
        .web_engine = .chromium,
        .cef_dir = ".zig-cache/missing-linux-cef",
    }));
}

test "android skeleton includes Gradle CMake Kotlin and JNI wiring" {
    const root = ".zig-cache/test-android-skeleton";
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(std.testing.io, root) catch {};
    _ = try createAndroidSkeleton(std.testing.io, root);

    try expectFileContains(root ++ "/settings.gradle", "include \":app\"");
    try expectFileContains(root ++ "/build.gradle", "org.jetbrains.kotlin.android");
    try expectFileContains(root ++ "/app/build.gradle", "externalNativeBuild");
    try expectFileContains(root ++ "/app/src/main/cpp/CMakeLists.txt", "lib/libzero-native.a");
    try expectFileContains(root ++ "/app/src/main/res/values/styles.xml", "AppTheme");
    try expectFileContains(root ++ "/app/src/main/java/dev/zero_native/examples/android/MainActivity.kt", "package dev.zero_native.examples.android");
    try expectFileContains(root ++ "/app/src/main/java/dev/zero_native/examples/android/MainActivity.kt", "System.loadLibrary(\"zero_native_example\")");
    try expectFileContains(root ++ "/app/src/main/cpp/zero_native_jni.c", "Java_dev_zero_1native_examples_android_MainActivity_nativeCreate");
    try expectFileContains(root ++ "/app/src/main/cpp/zero_native_jni.c", "zero_native_app_destroy");
}

test "package report records target signing and assets" {
    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .version = "1.2.3" };
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, ".zig-cache/test-package-report");
    var dir = try cwd.openDir(std.testing.io, ".zig-cache/test-package-report", .{});
    defer dir.close(std.testing.io);
    try writeReport(std.testing.allocator, dir, std.testing.io, "package-manifest.zon", .{
        .metadata = metadata,
        .target = .linux,
        .output_path = ".zig-cache/test-package-report",
        .signing = .{ .mode = .none },
    }, "demo", 2);
    var buffer: [512]u8 = undefined;
    var file = try dir.openFile(std.testing.io, "package-manifest.zon", .{});
    defer file.close(std.testing.io);
    const len = try file.readPositionalAll(std.testing.io, &buffer, 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], ".target = \"linux\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], ".asset_count = 2") != null);
}

fn expectFileContains(path: []const u8, needle: []const u8) !void {
    const bytes = try readPath(std.testing.allocator, std.testing.io, path);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, needle) != null);
}
