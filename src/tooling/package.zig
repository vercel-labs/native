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
    try validateWebEngineTarget(options.target, options.web_engine);
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

fn validateWebEngineTarget(target: PackageTarget, web_engine: WebEngine) !void {
    if (web_engine != .chromium) return;
    switch (target) {
        .macos, .ios, .android => {},
        .windows, .linux => return error.UnsupportedWebEngine,
    }
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
        try makeExecutable(package_dir, io, executable_subpath);
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
    try copyMacosDocumentIcons(allocator, io, package_dir, options.metadata);
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
    try dir.createDirPath(io, "Libraries");
    try dir.createDirPath(io, "zero-nativeHost");
    try writeFile(dir, io, "README.md", iosReadme());
    try writeFile(dir, io, "Info.plist", iosInfoPlist());
    try writeFile(dir, io, "zero-nativeHost/ZeroNativeShellConfig.swift", iosDefaultShellConfig());
    try writeFile(dir, io, "zero-nativeHost/ZeroNativeHostViewController.swift", iosViewController());
    try writeFile(dir, io, "zero-nativeHost/zero_native.h", embedHeader());
    return .{ .path = output_path, .target = .ios };
}

pub fn createAndroidSkeleton(io: std.Io, output_path: []const u8) !PackageStats {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, output_path);
    var dir = try cwd.openDir(io, output_path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "app/src/main/java/dev/zero_native");
    try dir.createDirPath(io, "app/src/main/cpp/lib");
    try dir.createDirPath(io, "app/src/main/res/values");
    try writeFile(dir, io, "README.md", androidReadme());
    try writeFile(dir, io, "settings.gradle", "pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }\ndependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { google(); mavenCentral() } }\nrootProject.name = 'zero-nativeHost'\ninclude ':app'\n");
    try writeFile(dir, io, "app/build.gradle", androidBuildGradle());
    try writeFile(dir, io, "app/src/main/AndroidManifest.xml", androidManifest());
    try writeFile(dir, io, "app/src/main/java/dev/zero_native/ZeroNativeShellConfig.kt", androidDefaultShellConfig());
    try writeFile(dir, io, "app/src/main/java/dev/zero_native/MainActivity.kt", androidActivity());
    try writeFile(dir, io, "app/src/main/cpp/CMakeLists.txt", androidCMakeLists());
    try writeFile(dir, io, "app/src/main/cpp/zero_native_jni.c", androidJni());
    try writeFile(dir, io, "app/src/main/cpp/zero_native.h", embedHeader());
    try writeFile(dir, io, "app/src/main/res/values/styles.xml", androidStyles());
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
        if (options.metadata.file_associations.len > 0) {
            try dir.createDirPath(io, "share/mime/packages");
            const mime_info = try linuxMimeInfo(allocator, options.metadata);
            defer allocator.free(mime_info);
            const mime_path = try std.fmt.allocPrint(allocator, "share/mime/packages/{s}.xml", .{options.metadata.name});
            defer allocator.free(mime_path);
            try writeFile(dir, io, mime_path, mime_info);
        }
        if (options.metadata.icons.len > 0) {
            copyFileToDir(allocator, io, dir, options.metadata.icons[0], "share/icons/app-icon.png") catch {};
        }
    } else if (options.target == .windows and hasRegistrationMetadata(options.metadata)) {
        try dir.createDirPath(io, "install");
        const registry_script = try windowsRegistrationScript(allocator, options.metadata, executable_name);
        defer allocator.free(registry_script);
        try writeFile(dir, io, "install/register-file-types.ps1", registry_script);
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
    const info_plist = try iosInfoPlistForMetadata(allocator, options.metadata);
    defer allocator.free(info_plist);
    try writeFile(dir, io, "Info.plist", info_plist);
    const shell_model = mobileShellModel(options.metadata);
    const shell_config = try iosShellConfigAlloc(allocator, shell_model);
    defer allocator.free(shell_config);
    try writeFile(dir, io, "zero-nativeHost/ZeroNativeShellConfig.swift", shell_config);
    const assets_output = try assetOutputPath(allocator, options.output_path, "Resources", options);
    defer allocator.free(assets_output);
    const bundle_stats = try assets_tool.bundle(allocator, io, options.assets_dir, assets_output);
    if (options.binary_path) |binary_path| try copyFileToDir(allocator, io, dir, binary_path, "Libraries/libzero-native.a");
    try writeReport(allocator, dir, io, "package-manifest.zon", options, "libzero-native.a", bundle_stats.asset_count);
    return .{ .path = options.output_path, .artifact_name = std.fs.path.basename(options.output_path), .target = .ios, .asset_count = bundle_stats.asset_count, .web_engine = options.web_engine };
}

fn createAndroidArtifact(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !PackageStats {
    _ = try createAndroidSkeleton(io, options.output_path);
    var dir = try std.Io.Dir.cwd().openDir(io, options.output_path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "app/src/main/cpp/lib");
    const build_gradle = try androidBuildGradleForMetadata(allocator, options.metadata);
    defer allocator.free(build_gradle);
    try writeFile(dir, io, "app/build.gradle", build_gradle);
    const manifest = try androidManifestForMetadata(allocator, options.metadata);
    defer allocator.free(manifest);
    try writeFile(dir, io, "app/src/main/AndroidManifest.xml", manifest);
    const shell_model = mobileShellModel(options.metadata);
    const shell_config = try androidShellConfigAlloc(allocator, shell_model);
    defer allocator.free(shell_config);
    try writeFile(dir, io, "app/src/main/java/dev/zero_native/ZeroNativeShellConfig.kt", shell_config);
    const assets_output = try assetOutputPath(allocator, options.output_path, "app/src/main/assets/zero-native", options);
    defer allocator.free(assets_output);
    const bundle_stats = try assets_tool.bundle(allocator, io, options.assets_dir, assets_output);
    if (options.binary_path) |binary_path| try copyFileToDir(allocator, io, dir, binary_path, "app/src/main/cpp/lib/libzero-native.a");
    try writeReport(allocator, dir, io, "package-manifest.zon", options, "libzero-native.a", bundle_stats.asset_count);
    return .{ .path = options.output_path, .artifact_name = std.fs.path.basename(options.output_path), .target = .android, .asset_count = bundle_stats.asset_count, .web_engine = options.web_engine };
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
    const document_types = try macosDocumentTypes(allocator, metadata);
    defer allocator.free(document_types);
    const url_types = try macosUrlTypes(allocator, metadata);
    defer allocator.free(url_types);
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
        \\  <key>LSMinimumSystemVersion</key>
        \\  <string>11.0</string>
        \\  <key>CFBundleShortVersionString</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleVersion</key>
        \\  <string>{s}</string>
        \\{s}{s}
        \\</dict>
        \\</plist>
        \\
    , .{ bundle_id, name, display_name, executable, icon, version, version, document_types, url_types });
}

fn embedHeader() []const u8 {
    return
    \\#pragma once
    \\#include <stdint.h>
    \\#include <stddef.h>
    \\enum {
    \\  ZERO_NATIVE_WIDGET_ROLE_NONE = 0,
    \\  ZERO_NATIVE_WIDGET_ROLE_GROUP = 1,
    \\  ZERO_NATIVE_WIDGET_ROLE_TEXT = 2,
    \\  ZERO_NATIVE_WIDGET_ROLE_IMAGE = 3,
    \\  ZERO_NATIVE_WIDGET_ROLE_BUTTON = 4,
    \\  ZERO_NATIVE_WIDGET_ROLE_TEXTBOX = 5,
    \\  ZERO_NATIVE_WIDGET_ROLE_TOOLTIP = 6,
    \\  ZERO_NATIVE_WIDGET_ROLE_DIALOG = 7,
    \\  ZERO_NATIVE_WIDGET_ROLE_MENU = 8,
    \\  ZERO_NATIVE_WIDGET_ROLE_MENUITEM = 9,
    \\  ZERO_NATIVE_WIDGET_ROLE_LIST = 10,
    \\  ZERO_NATIVE_WIDGET_ROLE_LISTITEM = 11,
    \\  ZERO_NATIVE_WIDGET_ROLE_ROW = 12,
    \\  ZERO_NATIVE_WIDGET_ROLE_GRID = 13,
    \\  ZERO_NATIVE_WIDGET_ROLE_GRIDCELL = 14,
    \\  ZERO_NATIVE_WIDGET_ROLE_TAB = 15,
    \\  ZERO_NATIVE_WIDGET_ROLE_CHECKBOX = 16,
    \\  ZERO_NATIVE_WIDGET_ROLE_SWITCH = 17,
    \\  ZERO_NATIVE_WIDGET_ROLE_SLIDER = 18,
    \\  ZERO_NATIVE_WIDGET_ROLE_PROGRESSBAR = 19,
    \\};
    \\enum {
    \\  ZERO_NATIVE_WIDGET_FLAG_FOCUSED = 1u << 0,
    \\  ZERO_NATIVE_WIDGET_FLAG_HOVERED = 1u << 1,
    \\  ZERO_NATIVE_WIDGET_FLAG_PRESSED = 1u << 2,
    \\  ZERO_NATIVE_WIDGET_FLAG_SELECTED = 1u << 3,
    \\  ZERO_NATIVE_WIDGET_FLAG_DISABLED = 1u << 4,
    \\  ZERO_NATIVE_WIDGET_FLAG_FOCUSABLE = 1u << 5,
    \\  ZERO_NATIVE_WIDGET_FLAG_EXPANDED = 1u << 6,
    \\  ZERO_NATIVE_WIDGET_FLAG_COLLAPSED = 1u << 7,
    \\  ZERO_NATIVE_WIDGET_FLAG_REQUIRED = 1u << 8,
    \\  ZERO_NATIVE_WIDGET_FLAG_READ_ONLY = 1u << 9,
    \\  ZERO_NATIVE_WIDGET_FLAG_INVALID = 1u << 10,
    \\};
    \\enum {
    \\  ZERO_NATIVE_WIDGET_ACTION_FOCUS = 1u << 0,
    \\  ZERO_NATIVE_WIDGET_ACTION_PRESS = 1u << 1,
    \\  ZERO_NATIVE_WIDGET_ACTION_TOGGLE = 1u << 2,
    \\  ZERO_NATIVE_WIDGET_ACTION_INCREMENT = 1u << 3,
    \\  ZERO_NATIVE_WIDGET_ACTION_DECREMENT = 1u << 4,
    \\  ZERO_NATIVE_WIDGET_ACTION_SET_TEXT = 1u << 5,
    \\  ZERO_NATIVE_WIDGET_ACTION_SET_SELECTION = 1u << 6,
    \\  ZERO_NATIVE_WIDGET_ACTION_SELECT = 1u << 7,
    \\  ZERO_NATIVE_WIDGET_ACTION_DRAG = 1u << 8,
    \\  ZERO_NATIVE_WIDGET_ACTION_DROP_FILES = 1u << 9,
    \\  ZERO_NATIVE_WIDGET_ACTION_DISMISS = 1u << 10,
    \\};
    \\enum {
    \\  ZERO_NATIVE_WIDGET_ACTION_KIND_FOCUS = 0,
    \\  ZERO_NATIVE_WIDGET_ACTION_KIND_PRESS = 1,
    \\  ZERO_NATIVE_WIDGET_ACTION_KIND_TOGGLE = 2,
    \\  ZERO_NATIVE_WIDGET_ACTION_KIND_INCREMENT = 3,
    \\  ZERO_NATIVE_WIDGET_ACTION_KIND_DECREMENT = 4,
    \\  ZERO_NATIVE_WIDGET_ACTION_KIND_SET_TEXT = 5,
    \\  ZERO_NATIVE_WIDGET_ACTION_KIND_SET_SELECTION = 6,
    \\  ZERO_NATIVE_WIDGET_ACTION_KIND_SET_COMPOSITION = 7,
    \\  ZERO_NATIVE_WIDGET_ACTION_KIND_COMMIT_COMPOSITION = 8,
    \\  ZERO_NATIVE_WIDGET_ACTION_KIND_CANCEL_COMPOSITION = 9,
    \\  ZERO_NATIVE_WIDGET_ACTION_KIND_SELECT = 10,
    \\  ZERO_NATIVE_WIDGET_ACTION_KIND_DRAG = 11,
    \\  ZERO_NATIVE_WIDGET_ACTION_KIND_DROP_FILES = 12,
    \\  ZERO_NATIVE_WIDGET_ACTION_KIND_DISMISS = 13,
    \\};
    \\enum {
    \\  ZERO_NATIVE_GPU_SURFACE_STATUS_UNAVAILABLE = 0,
    \\  ZERO_NATIVE_GPU_SURFACE_STATUS_INITIALIZING = 1,
    \\  ZERO_NATIVE_GPU_SURFACE_STATUS_READY = 2,
    \\  ZERO_NATIVE_GPU_SURFACE_STATUS_LOST = 3,
    \\};
    \\typedef struct zero_native_widget_semantics {
    \\  uint64_t id;
    \\  uint64_t parent_id;
    \\  int role;
    \\  uint32_t flags;
    \\  uint32_t actions;
    \\  float x;
    \\  float y;
    \\  float width;
    \\  float height;
    \\  float value;
    \\  int has_value;
    \\  const char *label;
    \\  uintptr_t label_len;
    \\  const char *text;
    \\  uintptr_t text_len;
    \\  const char *placeholder;
    \\  uintptr_t placeholder_len;
    \\  intptr_t text_selection_start;
    \\  intptr_t text_selection_end;
    \\  intptr_t text_composition_start;
    \\  intptr_t text_composition_end;
    \\  intptr_t grid_row_index;
    \\  intptr_t grid_column_index;
    \\  intptr_t grid_row_count;
    \\  intptr_t grid_column_count;
    \\  intptr_t list_item_index;
    \\  intptr_t list_item_count;
    \\  float scroll_offset;
    \\  float scroll_viewport_extent;
    \\  float scroll_content_extent;
    \\  int has_scroll;
    \\} zero_native_widget_semantics_t;
    \\typedef struct zero_native_widget_text_geometry {
    \\  uint64_t id;
    \\  int has_caret_bounds;
    \\  float caret_x;
    \\  float caret_y;
    \\  float caret_width;
    \\  float caret_height;
    \\  int has_selection_bounds;
    \\  float selection_x;
    \\  float selection_y;
    \\  float selection_width;
    \\  float selection_height;
    \\  uintptr_t selection_rect_count;
    \\  int has_composition_bounds;
    \\  float composition_x;
    \\  float composition_y;
    \\  float composition_width;
    \\  float composition_height;
    \\  uintptr_t composition_rect_count;
    \\} zero_native_widget_text_geometry_t;
    \\typedef struct zero_native_widget_action {
    \\  uint64_t id;
    \\  int action;
    \\  const char *text;
    \\  uintptr_t text_len;
    \\  uintptr_t selection_anchor;
    \\  uintptr_t selection_focus;
    \\  int has_selection;
    \\} zero_native_widget_action_t;
    \\typedef struct zero_native_viewport_state {
    \\  float width;
    \\  float height;
    \\  float scale;
    \\  int has_surface;
    \\  float safe_top;
    \\  float safe_right;
    \\  float safe_bottom;
    \\  float safe_left;
    \\  float keyboard_top;
    \\  float keyboard_right;
    \\  float keyboard_bottom;
    \\  float keyboard_left;
    \\  float content_x;
    \\  float content_y;
    \\  float content_width;
    \\  float content_height;
    \\} zero_native_viewport_state_t;
    \\typedef struct zero_native_gpu_frame_state {
    \\  uint64_t surface_id;
    \\  uint64_t window_id;
    \\  float width;
    \\  float height;
    \\  float scale;
    \\  uint64_t frame_index;
    \\  uint64_t timestamp_ns;
    \\  uint64_t frame_interval_ns;
    \\  uint64_t input_timestamp_ns;
    \\  uint64_t input_latency_ns;
    \\  uint64_t input_latency_budget_ns;
    \\  uintptr_t input_latency_budget_exceeded_count;
    \\  int input_latency_budget_ok;
    \\  uint64_t first_frame_latency_ns;
    \\  uint64_t first_frame_latency_budget_ns;
    \\  uintptr_t first_frame_latency_budget_exceeded_count;
    \\  int first_frame_latency_budget_ok;
    \\  int nonblank;
    \\  uint32_t sample_color;
    \\  int status;
    \\  int vsync;
    \\  uint64_t canvas_revision;
    \\  uintptr_t canvas_command_count;
    \\  int canvas_frame_requires_render;
    \\  int canvas_frame_full_repaint;
    \\  uintptr_t canvas_frame_batch_count;
    \\  uintptr_t canvas_frame_budget_exceeded_count;
    \\  int canvas_frame_budget_ok;
    \\  uint64_t widget_revision;
    \\  uintptr_t widget_node_count;
    \\  uintptr_t widget_semantics_count;
    \\} zero_native_gpu_frame_state_t;
    \\void *zero_native_app_create(void);
    \\void zero_native_app_destroy(void *app);
    \\void zero_native_app_start(void *app);
    \\void zero_native_app_activate(void *app);
    \\void zero_native_app_deactivate(void *app);
    \\void zero_native_app_stop(void *app);
    \\void zero_native_app_resize(void *app, float width, float height, float scale, void *surface);
    \\void zero_native_app_viewport(void *app, float width, float height, float scale, void *surface, float safe_top, float safe_right, float safe_bottom, float safe_left, float keyboard_top, float keyboard_right, float keyboard_bottom, float keyboard_left);
    \\int zero_native_app_viewport_state(void *app, zero_native_viewport_state_t *out);
    \\int zero_native_app_gpu_frame_state(void *app, zero_native_gpu_frame_state_t *out);
    \\void zero_native_app_touch(void *app, uint64_t id, int phase, float x, float y, float pressure);
    \\void zero_native_app_scroll(void *app, uint64_t id, float x, float y, float delta_x, float delta_y);
    \\void zero_native_app_key(void *app, int phase, const char *key, uintptr_t key_len, const char *text, uintptr_t text_len, uint32_t modifiers_mask);
    \\void zero_native_app_text(void *app, const char *text, uintptr_t len);
    \\void zero_native_app_ime(void *app, int kind, const char *text, uintptr_t len, intptr_t cursor);
    \\void zero_native_app_command(void *app, const char *name, uintptr_t len);
    \\void zero_native_app_frame(void *app);
    \\void zero_native_app_set_asset_root(void *app, const char *path, uintptr_t len);
    \\void zero_native_app_set_asset_entry(void *app, const char *path, uintptr_t len);
    \\uintptr_t zero_native_app_last_command_count(void *app);
    \\const char *zero_native_app_last_command_name(void *app);
    \\const char *zero_native_app_last_error_name(void *app);
    \\uintptr_t zero_native_app_widget_semantics_count(void *app);
    \\int zero_native_app_widget_semantics_at(void *app, uintptr_t index, zero_native_widget_semantics_t *out);
    \\int zero_native_app_widget_semantics_by_id(void *app, uint64_t id, zero_native_widget_semantics_t *out);
    \\int zero_native_app_widget_text_geometry(void *app, uint64_t id, zero_native_widget_text_geometry_t *out);
    \\int zero_native_app_widget_action(void *app, const zero_native_widget_action_t *action);
    \\
    ;
}

fn iosReadme() []const u8 {
    return "iOS zero-native host skeleton. Link Libraries/libzero-native.a and call the functions in zero-nativeHost/zero_native.h from the native UIKit shell.\n";
}

fn iosInfoPlist() []const u8 {
    return
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.zero_native.ios</string><key>CFBundleName</key><string>zero-nativeHost</string></dict></plist>
    \\
    ;
}

fn iosInfoPlistForMetadata(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]const u8 {
    const bundle_id = try xmlEscapeAlloc(allocator, metadata.id);
    defer allocator.free(bundle_id);
    const name = try xmlEscapeAlloc(allocator, metadata.name);
    defer allocator.free(name);
    const display_name = try xmlEscapeAlloc(allocator, metadata.displayName());
    defer allocator.free(display_name);
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
        \\  <key>CFBundleShortVersionString</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleVersion</key>
        \\  <string>{s}</string>
        \\</dict>
        \\</plist>
        \\
    , .{ bundle_id, name, display_name, version, version });
}

const MobileShellModel = struct {
    title: []const u8,
    status: []const u8,
    primary_button_title: []const u8,
    primary_command: []const u8,
    secondary_button_title: []const u8,
    secondary_command: []const u8,
    asset_root_subdirectory: []const u8,
    asset_entry_path: []const u8,
};

fn defaultMobileShellModel() MobileShellModel {
    return .{
        .title = "zero-native",
        .status = "Native commands ready",
        .primary_button_title = "Back",
        .primary_command = "mobile.back",
        .secondary_button_title = "Refresh",
        .secondary_command = "mobile.refresh",
        .asset_root_subdirectory = "",
        .asset_entry_path = "index.html",
    };
}

fn mobileShellModel(metadata: manifest_tool.Metadata) MobileShellModel {
    var model = defaultMobileShellModel();
    model.title = metadata.displayName();
    if (metadata.frontend) |frontend| {
        model.asset_root_subdirectory = frontend.dist;
        model.asset_entry_path = frontend.entry;
    }
    if (metadata.shell.windows.len == 0) return model;

    for (metadata.shell.windows[0].views) |view| {
        if (view.text) |text| {
            if (std.mem.eql(u8, view.label, "mobile-title")) {
                model.title = text;
            } else if (std.mem.eql(u8, view.label, "mobile-status") or std.mem.eql(u8, view.kind, "statusbar")) {
                model.status = text;
            }
        }
        if (view.command) |command| {
            const title = view.text orelse command;
            if (std.mem.eql(u8, view.label, "mobile-back") or std.mem.indexOf(u8, command, "back") != null) {
                model.primary_button_title = title;
                model.primary_command = command;
            } else if (std.mem.eql(u8, view.label, "mobile-refresh") or std.mem.indexOf(u8, command, "refresh") != null) {
                model.secondary_button_title = title;
                model.secondary_command = command;
            }
        }
    }
    return model;
}

const SourceStringTarget = enum {
    swift,
    kotlin,
};

fn sourceStringLiteralAlloc(allocator: std.mem.Allocator, value: []const u8, target: SourceStringTarget) ![]const u8 {
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
            '$' => if (target == .kotlin) try out.appendSlice(allocator, "\\$") else try out.append(allocator, ch),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn iosDefaultShellConfig() []const u8 {
    return
    \\enum ZeroNativeShellConfig {
    \\    static let title = "zero-native"
    \\    static let status = "Native commands ready"
    \\    static let primaryButtonTitle = "Back"
    \\    static let primaryCommand = "mobile.back"
    \\    static let secondaryButtonTitle = "Refresh"
    \\    static let secondaryCommand = "mobile.refresh"
    \\    static let assetRootSubdirectory = ""
    \\    static let assetEntryPath = "index.html"
    \\}
    \\
    ;
}

fn iosShellConfigAlloc(allocator: std.mem.Allocator, model: MobileShellModel) ![]const u8 {
    const title = try sourceStringLiteralAlloc(allocator, model.title, .swift);
    defer allocator.free(title);
    const status = try sourceStringLiteralAlloc(allocator, model.status, .swift);
    defer allocator.free(status);
    const primary_title = try sourceStringLiteralAlloc(allocator, model.primary_button_title, .swift);
    defer allocator.free(primary_title);
    const primary_command = try sourceStringLiteralAlloc(allocator, model.primary_command, .swift);
    defer allocator.free(primary_command);
    const secondary_title = try sourceStringLiteralAlloc(allocator, model.secondary_button_title, .swift);
    defer allocator.free(secondary_title);
    const secondary_command = try sourceStringLiteralAlloc(allocator, model.secondary_command, .swift);
    defer allocator.free(secondary_command);
    const asset_root = try sourceStringLiteralAlloc(allocator, model.asset_root_subdirectory, .swift);
    defer allocator.free(asset_root);
    const asset_entry = try sourceStringLiteralAlloc(allocator, model.asset_entry_path, .swift);
    defer allocator.free(asset_entry);

    return std.fmt.allocPrint(allocator,
        \\enum ZeroNativeShellConfig {{
        \\    static let title = {s}
        \\    static let status = {s}
        \\    static let primaryButtonTitle = {s}
        \\    static let primaryCommand = {s}
        \\    static let secondaryButtonTitle = {s}
        \\    static let secondaryCommand = {s}
        \\    static let assetRootSubdirectory = {s}
        \\    static let assetEntryPath = {s}
        \\}}
        \\
    , .{ title, status, primary_title, primary_command, secondary_title, secondary_command, asset_root, asset_entry });
}

fn iosViewController() []const u8 {
    return
    \\import UIKit
    \\import WebKit
    \\
    \\final class ZeroNativeHostViewController: UIViewController {
    \\    private let headerView = UIView()
    \\    private let titleLabel = UILabel()
    \\    private let statusLabel = UILabel()
    \\    private let backButton = UIButton(type: .system)
    \\    private let refreshButton = UIButton(type: .system)
    \\    private let webView = WKWebView(frame: .zero)
    \\    private var webViewBottomConstraint: NSLayoutConstraint?
    \\    private var nativeApp: UnsafeMutableRawPointer?
    \\    private var keyboardBottomInset: CGFloat = 0
    \\    private var widgetAccessibilityElements: [UIAccessibilityElement] = []
    \\
    \\    private struct WidgetSemantics {
    \\        let id: UInt64
    \\        let parentId: UInt64
    \\        let role: Int32
    \\        let flags: UInt32
    \\        let actions: UInt32
    \\        let bounds: CGRect
    \\        let value: Float?
    \\        let label: String
    \\        let text: String
    \\        let placeholder: String
    \\        let textSelectionStart: Int
    \\        let textSelectionEnd: Int
    \\        let textCompositionStart: Int
    \\        let textCompositionEnd: Int
    \\        let gridRowIndex: Int
    \\        let gridColumnIndex: Int
    \\        let gridRowCount: Int
    \\        let gridColumnCount: Int
    \\        let listItemIndex: Int
    \\        let listItemCount: Int
    \\        let scrollOffset: Float
    \\        let scrollViewportExtent: Float
    \\        let scrollContentExtent: Float
    \\        let hasScroll: Bool
    \\    }
    \\
    \\    private struct WidgetTextGeometry {
    \\        let id: UInt64
    \\        let caretBounds: CGRect?
    \\        let selectionBounds: CGRect?
    \\        let selectionRectCount: Int
    \\        let compositionBounds: CGRect?
    \\        let compositionRectCount: Int
    \\    }
    \\
    \\    private final class WidgetAccessibilityElement: UIAccessibilityElement {
    \\        private weak var owner: ZeroNativeHostViewController?
    \\        private let node: WidgetSemantics
    \\
    \\        init(accessibilityContainer container: Any, owner: ZeroNativeHostViewController, node: WidgetSemantics) {
    \\            self.owner = owner
    \\            self.node = node
    \\            super.init(accessibilityContainer: container)
    \\        }
    \\
    \\        override func accessibilityActivate() -> Bool {
    \\            owner?.activateWidgetAccessibilityNode(node) ?? false
    \\        }
    \\
    \\        override func accessibilityIncrement() {
    \\            _ = owner?.incrementWidgetAccessibilityNode(node)
    \\        }
    \\
    \\        override func accessibilityDecrement() {
    \\            _ = owner?.decrementWidgetAccessibilityNode(node)
    \\        }
    \\
    \\        override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
    \\            switch direction {
    \\            case .down, .right:
    \\                return owner?.incrementWidgetAccessibilityNode(node) ?? false
    \\            case .up, .left:
    \\                return owner?.decrementWidgetAccessibilityNode(node) ?? false
    \\            default:
    \\                return false
    \\            }
    \\        }
    \\
    \\        override func accessibilityPerformEscape() -> Bool {
    \\            owner?.dismissWidgetAccessibilityNode(node) ?? false
    \\        }
    \\    }
    \\
    \\    override func viewDidLoad() {
    \\        super.viewDidLoad()
    \\        view.backgroundColor = .systemBackground
    \\        configureHeader()
    \\
    \\        headerView.translatesAutoresizingMaskIntoConstraints = false
    \\        webView.translatesAutoresizingMaskIntoConstraints = false
    \\        view.addSubview(headerView)
    \\        view.addSubview(webView)
    \\        let bottom = webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    \\        webViewBottomConstraint = bottom
    \\        NSLayoutConstraint.activate([
    \\            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
    \\            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    \\            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
    \\            headerView.heightAnchor.constraint(equalToConstant: 92),
    \\            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
    \\            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    \\            webView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
    \\            bottom,
    \\        ])
    \\        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameWillChange), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    \\        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
    \\
    \\        nativeApp = zero_native_app_create()
    \\        if let nativeApp {
    \\            configureNativeAssetRoot(nativeApp)
    \\            zero_native_app_start(nativeApp)
    \\            refreshWidgetAccessibility()
    \\        }
    \\        loadWorkspace()
    \\    }
    \\
    \\    private func packagedAssetRootURL() -> URL? {
    \\        guard let resourceURL = Bundle.main.resourceURL else { return nil }
    \\        let resourcesURL = resourceURL.appendingPathComponent("Resources", isDirectory: true)
    \\        let roots: [URL]
    \\        if ZeroNativeShellConfig.assetRootSubdirectory.isEmpty {
    \\            roots = [resourceURL, resourcesURL]
    \\        } else {
    \\            roots = [
    \\                resourceURL.appendingPathComponent(ZeroNativeShellConfig.assetRootSubdirectory, isDirectory: true),
    \\                resourcesURL.appendingPathComponent(ZeroNativeShellConfig.assetRootSubdirectory, isDirectory: true),
    \\            ]
    \\        }
    \\        for rootURL in roots {
    \\            let entryURL = rootURL.appendingPathComponent(ZeroNativeShellConfig.assetEntryPath, isDirectory: false)
    \\            if FileManager.default.fileExists(atPath: entryURL.path) { return rootURL }
    \\        }
    \\        return roots.first
    \\    }
    \\
    \\    private func configureNativeAssetRoot(_ nativeApp: UnsafeMutableRawPointer) {
    \\        guard let rootURL = packagedAssetRootURL() else { return }
    \\        let path = rootURL.path
    \\        path.withCString { pointer in
    \\            zero_native_app_set_asset_root(nativeApp, pointer, UInt(path.utf8.count))
    \\        }
    \\        ZeroNativeShellConfig.assetEntryPath.withCString { pointer in
    \\            zero_native_app_set_asset_entry(nativeApp, pointer, UInt(ZeroNativeShellConfig.assetEntryPath.utf8.count))
    \\        }
    \\    }
    \\
    \\    private func loadWorkspace() {
    \\        if let rootURL = packagedAssetRootURL() {
    \\            let entryURL = rootURL.appendingPathComponent(ZeroNativeShellConfig.assetEntryPath, isDirectory: false)
    \\            if FileManager.default.fileExists(atPath: entryURL.path) {
    \\                webView.loadFileURL(entryURL, allowingReadAccessTo: rootURL)
    \\                return
    \\            }
    \\        }
    \\        webView.loadHTMLString(Self.html, baseURL: nil)
    \\    }
    \\
    \\    private func configureHeader() {
    \\        headerView.backgroundColor = .secondarySystemBackground
    \\        titleLabel.text = ZeroNativeShellConfig.title
    \\        titleLabel.font = .preferredFont(forTextStyle: .title2)
    \\        titleLabel.adjustsFontForContentSizeCategory = true
    \\        statusLabel.text = ZeroNativeShellConfig.status
    \\        statusLabel.font = .preferredFont(forTextStyle: .caption1)
    \\        statusLabel.textColor = .secondaryLabel
    \\        backButton.setTitle(ZeroNativeShellConfig.primaryButtonTitle, for: .normal)
    \\        backButton.addTarget(self, action: #selector(sendBackCommand), for: .touchUpInside)
    \\        refreshButton.setTitle(ZeroNativeShellConfig.secondaryButtonTitle, for: .normal)
    \\        refreshButton.addTarget(self, action: #selector(sendRefreshCommand), for: .touchUpInside)
    \\        [titleLabel, statusLabel, backButton, refreshButton].forEach {
    \\            $0.translatesAutoresizingMaskIntoConstraints = false
    \\            headerView.addSubview($0)
    \\        }
    \\        NSLayoutConstraint.activate([
    \\            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
    \\            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 16),
    \\            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
    \\            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
    \\            refreshButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
    \\            refreshButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
    \\            backButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -12),
    \\            backButton.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
    \\        ])
    \\    }
    \\
    \\    @objc private func sendBackCommand() {
    \\        dispatchNativeCommand(ZeroNativeShellConfig.primaryCommand)
    \\    }
    \\
    \\    @objc private func sendRefreshCommand() {
    \\        dispatchNativeCommand(ZeroNativeShellConfig.secondaryCommand)
    \\    }
    \\
    \\    private func dispatchNativeCommand(_ command: String) {
    \\        guard let nativeApp else { return }
    \\        command.withCString { pointer in
    \\            zero_native_app_command(nativeApp, pointer, UInt(command.utf8.count))
    \\        }
    \\        let count = zero_native_app_last_command_count(nativeApp)
    \\        let name = String(cString: zero_native_app_last_command_name(nativeApp))
    \\        statusLabel.text = "\(name) #\(count)"
    \\        zero_native_app_frame(nativeApp)
    \\        refreshWidgetAccessibility()
    \\    }
    \\
    \\    @objc private func keyboardFrameWillChange(_ notification: Notification) {
    \\        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
    \\        let keyboardFrame = view.convert(value.cgRectValue, from: nil)
    \\        keyboardBottomInset = max(0, view.bounds.maxY - keyboardFrame.minY)
    \\        webViewBottomConstraint?.constant = -keyboardBottomInset
    \\        view.layoutIfNeeded()
    \\        sendViewportUpdate()
    \\    }
    \\
    \\    @objc private func keyboardWillHide(_ notification: Notification) {
    \\        _ = notification
    \\        keyboardBottomInset = 0
    \\        webViewBottomConstraint?.constant = 0
    \\        view.layoutIfNeeded()
    \\        sendViewportUpdate()
    \\    }
    \\
    \\    override func viewDidLayoutSubviews() {
    \\        super.viewDidLayoutSubviews()
    \\        sendViewportUpdate()
    \\    }
    \\
    \\    private func sendViewportUpdate() {
    \\        guard let nativeApp else { return }
    \\        let scale = Float(view.window?.screen.scale ?? UIScreen.main.scale)
    \\        let safe = view.safeAreaInsets
    \\        zero_native_app_viewport(nativeApp, Float(webView.bounds.width), Float(webView.bounds.height), scale, nil, Float(safe.top), Float(safe.right), Float(safe.bottom), Float(safe.left), 0, 0, Float(keyboardBottomInset), 0)
    \\        zero_native_app_frame(nativeApp)
    \\        refreshWidgetAccessibility()
    \\    }
    \\
    \\    private func widgetSemanticsSnapshot() -> [WidgetSemantics] {
    \\        guard let nativeApp else { return [] }
    \\        let count = Int(zero_native_app_widget_semantics_count(nativeApp))
    \\        var nodes: [WidgetSemantics] = []
    \\        nodes.reserveCapacity(count)
    \\        for index in 0..<count {
    \\            if let node = widgetSemantics(at: index) {
    \\                nodes.append(node)
    \\            }
    \\        }
    \\        return nodes
    \\    }
    \\
    \\    private func widgetSemantics(at index: Int) -> WidgetSemantics? {
    \\        guard let nativeApp else { return nil }
    \\        var node = zero_native_widget_semantics_t()
    \\        guard zero_native_app_widget_semantics_at(nativeApp, UInt(index), &node) != 0 else { return nil }
    \\        return widgetSemantics(from: node)
    \\    }
    \\
    \\    private func widgetSemantics(id: UInt64) -> WidgetSemantics? {
    \\        guard let nativeApp else { return nil }
    \\        var node = zero_native_widget_semantics_t()
    \\        guard zero_native_app_widget_semantics_by_id(nativeApp, id, &node) != 0 else { return nil }
    \\        return widgetSemantics(from: node)
    \\    }
    \\
    \\    private func widgetSemantics(from node: zero_native_widget_semantics_t) -> WidgetSemantics {
    \\        return WidgetSemantics(
    \\            id: node.id,
    \\            parentId: node.parent_id,
    \\            role: Int32(node.role),
    \\            flags: node.flags,
    \\            actions: node.actions,
    \\            bounds: CGRect(x: CGFloat(node.x), y: CGFloat(node.y), width: CGFloat(node.width), height: CGFloat(node.height)),
    \\            value: node.has_value != 0 ? node.value : nil,
    \\            label: Self.utf8String(node.label, length: node.label_len),
    \\            text: Self.utf8String(node.text, length: node.text_len),
    \\            placeholder: Self.utf8String(node.placeholder, length: node.placeholder_len),
    \\            textSelectionStart: Int(node.text_selection_start),
    \\            textSelectionEnd: Int(node.text_selection_end),
    \\            textCompositionStart: Int(node.text_composition_start),
    \\            textCompositionEnd: Int(node.text_composition_end),
    \\            gridRowIndex: Int(node.grid_row_index),
    \\            gridColumnIndex: Int(node.grid_column_index),
    \\            gridRowCount: Int(node.grid_row_count),
    \\            gridColumnCount: Int(node.grid_column_count),
    \\            listItemIndex: Int(node.list_item_index),
    \\            listItemCount: Int(node.list_item_count),
    \\            scrollOffset: node.scroll_offset,
    \\            scrollViewportExtent: node.scroll_viewport_extent,
    \\            scrollContentExtent: node.scroll_content_extent,
    \\            hasScroll: node.has_scroll != 0
    \\        )
    \\    }
    \\
    \\    private func widgetTextGeometry(id: UInt64) -> WidgetTextGeometry? {
    \\        guard let nativeApp else { return nil }
    \\        var geometry = zero_native_widget_text_geometry_t()
    \\        guard zero_native_app_widget_text_geometry(nativeApp, id, &geometry) != 0 else { return nil }
    \\        return WidgetTextGeometry(
    \\            id: id,
    \\            caretBounds: geometry.has_caret_bounds != 0 ? CGRect(x: CGFloat(geometry.caret_x), y: CGFloat(geometry.caret_y), width: CGFloat(geometry.caret_width), height: CGFloat(geometry.caret_height)) : nil,
    \\            selectionBounds: geometry.has_selection_bounds != 0 ? CGRect(x: CGFloat(geometry.selection_x), y: CGFloat(geometry.selection_y), width: CGFloat(geometry.selection_width), height: CGFloat(geometry.selection_height)) : nil,
    \\            selectionRectCount: Int(geometry.selection_rect_count),
    \\            compositionBounds: geometry.has_composition_bounds != 0 ? CGRect(x: CGFloat(geometry.composition_x), y: CGFloat(geometry.composition_y), width: CGFloat(geometry.composition_width), height: CGFloat(geometry.composition_height)) : nil,
    \\            compositionRectCount: Int(geometry.composition_rect_count)
    \\        )
    \\    }
    \\
    \\    @discardableResult
    \\    private func dispatchWidgetAction(
    \\        id: UInt64,
    \\        action: Int32,
    \\        text: String? = nil,
    \\        selectionAnchor: UInt = 0,
    \\        selectionFocus: UInt = 0,
    \\        hasSelection: Bool = false
    \\    ) -> Bool {
    \\        guard let nativeApp else { return false }
    \\        var request = zero_native_widget_action_t()
    \\        request.id = id
    \\        request.action = action
    \\        request.selection_anchor = selectionAnchor
    \\        request.selection_focus = selectionFocus
    \\        request.has_selection = hasSelection ? 1 : 0
    \\        let ok: Int32
    \\        if let text {
    \\            ok = text.withCString { pointer in
    \\                request.text = pointer
    \\                request.text_len = UInt(text.utf8.count)
    \\                return zero_native_app_widget_action(nativeApp, &request)
    \\            }
    \\        } else {
    \\            request.text = nil
    \\            request.text_len = 0
    \\            ok = zero_native_app_widget_action(nativeApp, &request)
    \\        }
    \\        if ok != 0 {
    \\            zero_native_app_frame(nativeApp)
    \\            refreshWidgetAccessibility()
    \\        }
    \\        return ok != 0
    \\    }
    \\
    \\    private func refreshWidgetAccessibility() {
    \\        let semantics = widgetSemanticsSnapshot()
    \\        statusLabel.accessibilityValue = "Accessible items: \(semantics.count)"
    \\        widgetAccessibilityElements = semantics.map { node in
    \\            let element = WidgetAccessibilityElement(accessibilityContainer: webView, owner: self, node: node)
    \\            element.accessibilityIdentifier = "zero-native-widget-\(node.id)"
    \\            element.accessibilityLabel = node.label.isEmpty ? node.text : node.label
    \\            element.accessibilityValue = widgetAccessibilityValue(node)
    \\            if !node.placeholder.isEmpty && node.text.isEmpty {
    \\                element.accessibilityHint = node.placeholder
    \\            }
    \\            element.accessibilityFrameInContainerSpace = node.bounds
    \\            element.accessibilityTraits = widgetAccessibilityTraits(node)
    \\            return element
    \\        }
    \\        webView.accessibilityElements = widgetAccessibilityElements.isEmpty ? nil : widgetAccessibilityElements as [Any]
    \\    }
    \\
    \\    private func widgetAccessibilityValue(_ node: WidgetSemantics) -> String? {
    \\        var states: [String] = []
    \\        if (node.flags & UInt32(ZERO_NATIVE_WIDGET_FLAG_EXPANDED)) != 0 {
    \\            states.append("Expanded")
    \\        }
    \\        if (node.flags & UInt32(ZERO_NATIVE_WIDGET_FLAG_COLLAPSED)) != 0 {
    \\            states.append("Collapsed")
    \\        }
    \\        if (node.flags & UInt32(ZERO_NATIVE_WIDGET_FLAG_REQUIRED)) != 0 {
    \\            states.append("Required")
    \\        }
    \\        if (node.flags & UInt32(ZERO_NATIVE_WIDGET_FLAG_READ_ONLY)) != 0 {
    \\            states.append("Read only")
    \\        }
    \\        if (node.flags & UInt32(ZERO_NATIVE_WIDGET_FLAG_INVALID)) != 0 {
    \\            states.append("Invalid")
    \\        }
    \\        if !states.isEmpty {
    \\            return states.joined(separator: ", ")
    \\        }
    \\        if let value = node.value {
    \\            switch node.role {
    \\            case Int32(ZERO_NATIVE_WIDGET_ROLE_CHECKBOX), Int32(ZERO_NATIVE_WIDGET_ROLE_SWITCH):
    \\                return value >= 0.5 ? "On" : "Off"
    \\            case Int32(ZERO_NATIVE_WIDGET_ROLE_SLIDER), Int32(ZERO_NATIVE_WIDGET_ROLE_PROGRESSBAR):
    \\                return "\(Int((value * 100).rounded()))%"
    \\            default:
    \\                return "\(value)"
    \\            }
    \\        }
    \\        return node.text.isEmpty ? nil : node.text
    \\    }
    \\
    \\    private func activateWidgetAccessibilityNode(_ node: WidgetSemantics) -> Bool {
    \\        let current = widgetSemantics(id: node.id) ?? node
    \\        if widgetSupportsAction(current, UInt32(ZERO_NATIVE_WIDGET_ACTION_TOGGLE)) {
    \\            return dispatchWidgetAction(id: current.id, action: Int32(ZERO_NATIVE_WIDGET_ACTION_KIND_TOGGLE))
    \\        }
    \\        if widgetSupportsAction(current, UInt32(ZERO_NATIVE_WIDGET_ACTION_PRESS)) {
    \\            return dispatchWidgetAction(id: current.id, action: Int32(ZERO_NATIVE_WIDGET_ACTION_KIND_PRESS))
    \\        }
    \\        if widgetSupportsAction(current, UInt32(ZERO_NATIVE_WIDGET_ACTION_SELECT)) {
    \\            return dispatchWidgetAction(id: current.id, action: Int32(ZERO_NATIVE_WIDGET_ACTION_KIND_SELECT))
    \\        }
    \\        return false
    \\    }
    \\
    \\    private func incrementWidgetAccessibilityNode(_ node: WidgetSemantics) -> Bool {
    \\        let current = widgetSemantics(id: node.id) ?? node
    \\        guard widgetSupportsAction(current, UInt32(ZERO_NATIVE_WIDGET_ACTION_INCREMENT)) else { return false }
    \\        return dispatchWidgetAction(id: current.id, action: Int32(ZERO_NATIVE_WIDGET_ACTION_KIND_INCREMENT))
    \\    }
    \\
    \\    private func decrementWidgetAccessibilityNode(_ node: WidgetSemantics) -> Bool {
    \\        let current = widgetSemantics(id: node.id) ?? node
    \\        guard widgetSupportsAction(current, UInt32(ZERO_NATIVE_WIDGET_ACTION_DECREMENT)) else { return false }
    \\        return dispatchWidgetAction(id: current.id, action: Int32(ZERO_NATIVE_WIDGET_ACTION_KIND_DECREMENT))
    \\    }
    \\
    \\    private func dismissWidgetAccessibilityNode(_ node: WidgetSemantics) -> Bool {
    \\        let current = widgetSemantics(id: node.id) ?? node
    \\        guard widgetSupportsAction(current, UInt32(ZERO_NATIVE_WIDGET_ACTION_DISMISS)) else { return false }
    \\        return dispatchWidgetAction(id: current.id, action: Int32(ZERO_NATIVE_WIDGET_ACTION_KIND_DISMISS))
    \\    }
    \\
    \\    private func widgetSupportsAction(_ node: WidgetSemantics, _ action: UInt32) -> Bool {
    \\        return (node.actions & action) != 0
    \\    }
    \\
    \\    private func widgetAccessibilityTraits(_ node: WidgetSemantics) -> UIAccessibilityTraits {
    \\        var traits: UIAccessibilityTraits = []
    \\        switch node.role {
    \\        case Int32(ZERO_NATIVE_WIDGET_ROLE_BUTTON), Int32(ZERO_NATIVE_WIDGET_ROLE_MENUITEM):
    \\            traits.insert(.button)
    \\        case Int32(ZERO_NATIVE_WIDGET_ROLE_CHECKBOX), Int32(ZERO_NATIVE_WIDGET_ROLE_SWITCH), Int32(ZERO_NATIVE_WIDGET_ROLE_TAB):
    \\            traits.insert(.button)
    \\        case Int32(ZERO_NATIVE_WIDGET_ROLE_SLIDER):
    \\            traits.insert(.adjustable)
    \\        case Int32(ZERO_NATIVE_WIDGET_ROLE_IMAGE):
    \\            traits.insert(.image)
    \\        case Int32(ZERO_NATIVE_WIDGET_ROLE_TEXT), Int32(ZERO_NATIVE_WIDGET_ROLE_PROGRESSBAR):
    \\            traits.insert(.staticText)
    \\        default:
    \\            break
    \\        }
    \\        if (node.flags & UInt32(ZERO_NATIVE_WIDGET_FLAG_SELECTED)) != 0 {
    \\            traits.insert(.selected)
    \\        }
    \\        if (node.flags & UInt32(ZERO_NATIVE_WIDGET_FLAG_DISABLED)) != 0 {
    \\            traits.insert(.notEnabled)
    \\        }
    \\        return traits
    \\    }
    \\
    \\    private static func utf8String(_ pointer: UnsafePointer<CChar>?, length: UInt) -> String {
    \\        guard let pointer, length > 0 else { return "" }
    \\        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(length))
    \\        return String(decoding: bytes, as: UTF8.self)
    \\    }
    \\
    \\    deinit {
    \\        NotificationCenter.default.removeObserver(self)
    \\        guard let nativeApp else { return }
    \\        zero_native_app_stop(nativeApp)
    \\        zero_native_app_destroy(nativeApp)
    \\    }
    \\
    \\    private static let html = """
    \\    <!doctype html>
    \\    <meta name="viewport" content="width=device-width, initial-scale=1">
    \\    <body style="margin:0;font-family:-apple-system,system-ui;background:#f7f8fa;color:#171717">
    \\      <main style="padding:28px 22px;display:grid;gap:16px">
    \\        <h1 style="margin:0;font-size:30px">Workspace</h1>
    \\        <p style="margin:0;color:#5f6672;line-height:1.5">This content is rendered by WKWebView while the header remains native UIKit.</p>
    \\      </main>
    \\    </body>
    \\    """
    \\}
    \\
    ;
}

fn androidReadme() []const u8 {
    return "Android zero-native host skeleton. Copy libzero-native.a into app/src/main/cpp/lib and build with Android Studio or Gradle.\n";
}

fn androidBuildGradle() []const u8 {
    return
    \\plugins {
    \\    id "com.android.application" version "8.5.0"
    \\    id "org.jetbrains.kotlin.android" version "2.0.20"
    \\}
    \\
    \\android {
    \\    namespace "dev.zero_native"
    \\    compileSdk 35
    \\
    \\    defaultConfig {
    \\        applicationId "dev.zero_native"
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

fn androidBuildGradleForMetadata(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]const u8 {
    const application_id = try androidApplicationIdAlloc(allocator, metadata.id);
    defer allocator.free(application_id);
    return std.fmt.allocPrint(allocator,
        \\plugins {{
        \\    id "com.android.application" version "8.5.0"
        \\    id "org.jetbrains.kotlin.android" version "2.0.20"
        \\}}
        \\
        \\android {{
        \\    namespace "{s}"
        \\    compileSdk 35
        \\
        \\    defaultConfig {{
        \\        applicationId "{s}"
        \\        minSdk 26
        \\        targetSdk 35
        \\        versionCode 1
        \\        versionName "{s}"
        \\
        \\        externalNativeBuild {{
        \\            cmake {{
        \\                arguments "-DANDROID_STL=c++_shared"
        \\            }}
        \\        }}
        \\    }}
        \\
        \\    externalNativeBuild {{
        \\        cmake {{
        \\            path "src/main/cpp/CMakeLists.txt"
        \\        }}
        \\    }}
        \\}}
        \\
    , .{ application_id, application_id, metadata.version });
}

fn androidCMakeLists() []const u8 {
    return
    \\cmake_minimum_required(VERSION 3.22.1)
    \\
    \\project(zero_native_host C)
    \\
    \\add_library(zero-native STATIC IMPORTED)
    \\set_target_properties(zero-native PROPERTIES
    \\    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/lib/libzero-native.a"
    \\)
    \\
    \\add_library(zero_native_host SHARED zero_native_jni.c)
    \\target_include_directories(zero_native_host PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    \\target_link_libraries(zero_native_host zero-native android log)
    \\
    ;
}

fn androidManifest() []const u8 {
    return "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"><application android:theme=\"@style/AppTheme\"><activity android:name=\"dev.zero_native.MainActivity\" android:configChanges=\"keyboard|keyboardHidden|orientation|screenSize\" android:exported=\"true\" android:windowSoftInputMode=\"adjustResize\"><intent-filter><action android:name=\"android.intent.action.MAIN\"/><category android:name=\"android.intent.category.LAUNCHER\"/></intent-filter></activity></application></manifest>\n";
}

fn androidManifestForMetadata(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]const u8 {
    const label = try xmlEscapeAlloc(allocator, metadata.displayName());
    defer allocator.free(label);
    return std.fmt.allocPrint(allocator,
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android">
        \\  <application android:label="{s}" android:theme="@style/AppTheme">
        \\    <activity android:name="dev.zero_native.MainActivity" android:configChanges="keyboard|keyboardHidden|orientation|screenSize" android:exported="true" android:windowSoftInputMode="adjustResize">
        \\      <intent-filter>
        \\        <action android:name="android.intent.action.MAIN" />
        \\        <category android:name="android.intent.category.LAUNCHER" />
        \\      </intent-filter>
        \\    </activity>
        \\  </application>
        \\</manifest>
        \\
    , .{label});
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

fn androidApplicationIdAlloc(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var segment_start = true;
    for (id) |ch| {
        if (ch == '.') {
            try out.append(allocator, '.');
            segment_start = true;
            continue;
        }
        if (segment_start and !std.ascii.isAlphabetic(ch)) {
            try out.append(allocator, 'a');
        }
        segment_start = false;
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '_');
        }
    }
    return out.toOwnedSlice(allocator);
}

fn androidDefaultShellConfig() []const u8 {
    return
    \\package dev.zero_native
    \\
    \\object ZeroNativeShellConfig {
    \\    const val title = "zero-native"
    \\    const val status = "Native commands ready"
    \\    const val primaryButtonTitle = "Back"
    \\    const val primaryCommand = "mobile.back"
    \\    const val secondaryButtonTitle = "Refresh"
    \\    const val secondaryCommand = "mobile.refresh"
    \\    const val assetRootSubdirectory = ""
    \\    const val assetEntryPath = "index.html"
    \\}
    \\
    ;
}

fn androidShellConfigAlloc(allocator: std.mem.Allocator, model: MobileShellModel) ![]const u8 {
    const title = try sourceStringLiteralAlloc(allocator, model.title, .kotlin);
    defer allocator.free(title);
    const status = try sourceStringLiteralAlloc(allocator, model.status, .kotlin);
    defer allocator.free(status);
    const primary_title = try sourceStringLiteralAlloc(allocator, model.primary_button_title, .kotlin);
    defer allocator.free(primary_title);
    const primary_command = try sourceStringLiteralAlloc(allocator, model.primary_command, .kotlin);
    defer allocator.free(primary_command);
    const secondary_title = try sourceStringLiteralAlloc(allocator, model.secondary_button_title, .kotlin);
    defer allocator.free(secondary_title);
    const secondary_command = try sourceStringLiteralAlloc(allocator, model.secondary_command, .kotlin);
    defer allocator.free(secondary_command);
    const asset_root = try sourceStringLiteralAlloc(allocator, model.asset_root_subdirectory, .kotlin);
    defer allocator.free(asset_root);
    const asset_entry = try sourceStringLiteralAlloc(allocator, model.asset_entry_path, .kotlin);
    defer allocator.free(asset_entry);

    return std.fmt.allocPrint(allocator,
        \\package dev.zero_native
        \\
        \\object ZeroNativeShellConfig {{
        \\    const val title = {s}
        \\    const val status = {s}
        \\    const val primaryButtonTitle = {s}
        \\    const val primaryCommand = {s}
        \\    const val secondaryButtonTitle = {s}
        \\    const val secondaryCommand = {s}
        \\    const val assetRootSubdirectory = {s}
        \\    const val assetEntryPath = {s}
        \\}}
        \\
    , .{ title, status, primary_title, primary_command, secondary_title, secondary_command, asset_root, asset_entry });
}

fn androidActivity() []const u8 {
    return
    \\package dev.zero_native
    \\
    \\import android.app.Activity
    \\import android.content.res.Configuration
    \\import android.graphics.Color
    \\import android.graphics.Rect
    \\import android.net.Uri
    \\import android.os.Build
    \\import android.os.Bundle
    \\import android.view.MotionEvent
    \\import android.view.SurfaceHolder
    \\import android.view.SurfaceView
    \\import android.view.View
    \\import android.view.accessibility.AccessibilityEvent
    \\import android.view.accessibility.AccessibilityNodeInfo
    \\import android.view.accessibility.AccessibilityNodeProvider
    \\import android.webkit.WebView
    \\import android.widget.Button
    \\import android.widget.FrameLayout
    \\import android.widget.LinearLayout
    \\import android.widget.TextView
    \\
    \\class MainActivity : Activity(), SurfaceHolder.Callback {
    \\    private var nativeApp: Long = 0
    \\    private lateinit var statusLabel: TextView
    \\    private lateinit var widgetSurface: WidgetSurfaceView
    \\    private var currentSurfaceHolder: SurfaceHolder? = null
    \\    private var lastTouchX: Float = 0f
    \\    private var lastTouchY: Float = 0f
    \\    private var lastTouchActive: Boolean = false
    \\
    \\    data class WidgetSemantics(
    \\        val id: Long,
    \\        val parentId: Long,
    \\        val role: Int,
    \\        val flags: Int,
    \\        val actions: Int,
    \\        val x: Float,
    \\        val y: Float,
    \\        val width: Float,
    \\        val height: Float,
    \\        val value: Float?,
    \\        val label: String,
    \\        val text: String,
    \\        val placeholder: String,
    \\        val textSelectionStart: Long,
    \\        val textSelectionEnd: Long,
    \\        val textCompositionStart: Long,
    \\        val textCompositionEnd: Long,
    \\        val gridRowIndex: Long,
    \\        val gridColumnIndex: Long,
    \\        val gridRowCount: Long,
    \\        val gridColumnCount: Long,
    \\        val listItemIndex: Long,
    \\        val listItemCount: Long,
    \\        val scrollOffset: Float,
    \\        val scrollViewportExtent: Float,
    \\        val scrollContentExtent: Float,
    \\        val hasScroll: Boolean,
    \\    )
    \\
    \\    data class WidgetTextGeometry(
    \\        val id: Long,
    \\        val hasCaretBounds: Boolean,
    \\        val caretX: Float,
    \\        val caretY: Float,
    \\        val caretWidth: Float,
    \\        val caretHeight: Float,
    \\        val hasSelectionBounds: Boolean,
    \\        val selectionX: Float,
    \\        val selectionY: Float,
    \\        val selectionWidth: Float,
    \\        val selectionHeight: Float,
    \\        val selectionRectCount: Int,
    \\        val hasCompositionBounds: Boolean,
    \\        val compositionX: Float,
    \\        val compositionY: Float,
    \\        val compositionWidth: Float,
    \\        val compositionHeight: Float,
    \\        val compositionRectCount: Int,
    \\    )
    \\
    \\    private inner class WidgetSurfaceView : SurfaceView(this@MainActivity) {
    \\        private val provider = WidgetAccessibilityProvider(this)
    \\
    \\        init {
    \\            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
    \\            isFocusable = true
    \\        }
    \\
    \\        override fun getAccessibilityNodeProvider(): AccessibilityNodeProvider = provider
    \\
    \\        fun notifyWidgetSemanticsChanged() {
    \\            invalidate()
    \\            provider.notifyWidgetSemanticsChanged()
    \\        }
    \\    }
    \\
    \\    private inner class WidgetAccessibilityProvider(private val host: View) : AccessibilityNodeProvider() {
    \\        private var accessibilityFocusedId: Long = 0
    \\
    \\        override fun createAccessibilityNodeInfo(virtualViewId: Int): AccessibilityNodeInfo? {
    \\            val nodes = widgetSemanticsSnapshot()
    \\            return if (virtualViewId == View.NO_ID) {
    \\                createHostNode(nodes)
    \\            } else {
    \\                (widgetSemanticsById(virtualViewId.toLong()) ?: nodes.firstOrNull { it.id.toInt() == virtualViewId })?.let { createWidgetNode(it, nodes) }
    \\            }
    \\        }
    \\
    \\        override fun performAction(virtualViewId: Int, action: Int, arguments: Bundle?): Boolean {
    \\            if (virtualViewId == View.NO_ID) return false
    \\            val node = widgetSemanticsById(virtualViewId.toLong()) ?: return false
    \\            val id = node.id
    \\            val handled = when (action) {
    \\                AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS -> {
    \\                    accessibilityFocusedId = id
    \\                    host.invalidate()
    \\                    sendVirtualEvent(id, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED)
    \\                    true
    \\                }
    \\                AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS -> {
    \\                    if (accessibilityFocusedId == id) accessibilityFocusedId = 0
    \\                    host.invalidate()
    \\                    sendVirtualEvent(id, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED)
    \\                    true
    \\                }
    \\                AccessibilityNodeInfo.ACTION_FOCUS -> {
    \\                    if (widgetSupportsAction(node, WIDGET_ACTION_FOCUS)) dispatchWidgetAction(id, WIDGET_ACTION_KIND_FOCUS) else false
    \\                }
    \\                AccessibilityNodeInfo.ACTION_CLICK -> performWidgetClick(id)
    \\                AccessibilityNodeInfo.ACTION_SELECT -> {
    \\                    if (widgetSupportsAction(node, WIDGET_ACTION_SELECT)) dispatchWidgetAction(id, WIDGET_ACTION_KIND_SELECT) else false
    \\                }
    \\                AccessibilityNodeInfo.ACTION_SCROLL_FORWARD -> {
    \\                    if (widgetSupportsAction(node, WIDGET_ACTION_INCREMENT)) dispatchWidgetAction(id, WIDGET_ACTION_KIND_INCREMENT) else false
    \\                }
    \\                AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD -> {
    \\                    if (widgetSupportsAction(node, WIDGET_ACTION_DECREMENT)) dispatchWidgetAction(id, WIDGET_ACTION_KIND_DECREMENT) else false
    \\                }
    \\                AccessibilityNodeInfo.ACTION_DISMISS -> {
    \\                    if (widgetSupportsAction(node, WIDGET_ACTION_DISMISS)) dispatchWidgetAction(id, WIDGET_ACTION_KIND_DISMISS) else false
    \\                }
    \\                AccessibilityNodeInfo.ACTION_SET_TEXT -> {
    \\                    val text = arguments?.getCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE)?.toString()
    \\                    if (text != null && widgetSupportsAction(node, WIDGET_ACTION_SET_TEXT)) dispatchWidgetAction(id, WIDGET_ACTION_KIND_SET_TEXT, text) else false
    \\                }
    \\                AccessibilityNodeInfo.ACTION_SET_SELECTION -> {
    \\                    val start = arguments?.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, -1) ?: -1
    \\                    val end = arguments?.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, -1) ?: -1
    \\                    if (start >= 0 && end >= 0 && widgetSupportsAction(node, WIDGET_ACTION_SET_SELECTION)) {
    \\                        dispatchWidgetAction(id, WIDGET_ACTION_KIND_SET_SELECTION, selectionAnchor = start.toLong(), selectionFocus = end.toLong(), hasSelection = true)
    \\                    } else {
    \\                        false
    \\                    }
    \\                }
    \\                else -> false
    \\            }
    \\            if (handled) host.invalidate()
    \\            return handled
    \\        }
    \\
    \\        fun notifyWidgetSemanticsChanged() {
    \\            val event = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
    \\            event.setSource(host)
    \\            event.packageName = packageName
    \\            event.contentChangeTypes = AccessibilityEvent.CONTENT_CHANGE_TYPE_SUBTREE
    \\            host.parent?.requestSendAccessibilityEvent(host, event)
    \\        }
    \\
    \\        private fun createHostNode(nodes: List<WidgetSemantics>): AccessibilityNodeInfo {
    \\            val info = AccessibilityNodeInfo.obtain(host)
    \\            host.onInitializeAccessibilityNodeInfo(info)
    \\            info.className = SurfaceView::class.java.name
    \\            for (node in nodes.filter { it.parentId == 0L }) {
    \\                info.addChild(host, node.id.toInt())
    \\            }
    \\            return info
    \\        }
    \\
    \\        private fun createWidgetNode(node: WidgetSemantics, nodes: List<WidgetSemantics>): AccessibilityNodeInfo {
    \\            val info = AccessibilityNodeInfo.obtain()
    \\            val virtualId = node.id.toInt()
    \\            val parentNode = nodes.firstOrNull { it.id == node.parentId }
    \\            info.setSource(host, virtualId)
    \\            if (parentNode != null) {
    \\                info.setParent(host, parentNode.id.toInt())
    \\            } else {
    \\                info.setParent(host)
    \\            }
    \\            for (child in nodes.filter { it.parentId == node.id }) {
    \\                info.addChild(host, child.id.toInt())
    \\            }
    \\            info.packageName = packageName
    \\            info.className = widgetAccessibilityClassName(node)
    \\            info.contentDescription = node.label.ifEmpty { node.text }
    \\            if (node.text.isNotEmpty()) info.text = node.text
    \\            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && node.placeholder.isNotEmpty() && node.text.isEmpty()) {
    \\                info.hintText = node.placeholder
    \\            }
    \\            info.isVisibleToUser = host.isShown
    \\            info.isEnabled = (node.flags and WIDGET_FLAG_DISABLED) == 0
    \\            info.isFocusable = (node.flags and WIDGET_FLAG_FOCUSABLE) != 0
    \\            info.isFocused = (node.flags and WIDGET_FLAG_FOCUSED) != 0
    \\            info.isAccessibilityFocused = accessibilityFocusedId == node.id
    \\            info.isSelected = (node.flags and WIDGET_FLAG_SELECTED) != 0
    \\            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
    \\                info.stateDescription = widgetStateDescription(node)
    \\            }
    \\            info.isCheckable = node.role == WIDGET_ROLE_CHECKBOX || node.role == WIDGET_ROLE_SWITCH
    \\            info.isChecked = info.isCheckable && widgetValueSelected(node)
    \\            info.isClickable = widgetSupportsAnyAction(node, WIDGET_ACTION_PRESS or WIDGET_ACTION_TOGGLE or WIDGET_ACTION_SELECT)
    \\            info.isEditable = node.role == WIDGET_ROLE_TEXTBOX && (node.flags and WIDGET_FLAG_READ_ONLY) == 0
    \\            info.isScrollable = node.hasScroll
    \\            if (node.value != null) {
    \\                info.setRangeInfo(AccessibilityNodeInfo.RangeInfo.obtain(AccessibilityNodeInfo.RangeInfo.RANGE_TYPE_FLOAT, 0f, 1f, node.value))
    \\            }
    \\            setCollectionInfo(info, node, nodes)
    \\            setCollectionItemInfo(info, node)
    \\            if (node.textSelectionStart >= 0 && node.textSelectionEnd >= 0) {
    \\                info.setTextSelection(node.textSelectionStart.toInt(), node.textSelectionEnd.toInt())
    \\            }
    \\            if (accessibilityFocusedId == node.id) {
    \\                info.addAction(AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS)
    \\            } else {
    \\                info.addAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)
    \\            }
    \\            if (info.isFocusable) info.addAction(AccessibilityNodeInfo.ACTION_FOCUS)
    \\            if (info.isClickable) info.addAction(AccessibilityNodeInfo.ACTION_CLICK)
    \\            if (widgetSupportsAction(node, WIDGET_ACTION_SELECT)) info.addAction(AccessibilityNodeInfo.ACTION_SELECT)
    \\            if (widgetSupportsAction(node, WIDGET_ACTION_INCREMENT)) info.addAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
    \\            if (widgetSupportsAction(node, WIDGET_ACTION_DECREMENT)) info.addAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
    \\            if (widgetSupportsAction(node, WIDGET_ACTION_DISMISS)) info.addAction(AccessibilityNodeInfo.ACTION_DISMISS)
    \\            if (widgetSupportsAction(node, WIDGET_ACTION_SET_TEXT)) info.addAction(AccessibilityNodeInfo.ACTION_SET_TEXT)
    \\            if (widgetSupportsAction(node, WIDGET_ACTION_SET_SELECTION)) info.addAction(AccessibilityNodeInfo.ACTION_SET_SELECTION)
    \\            info.setBoundsInParent(boundsInParent(node, parentNode))
    \\            val location = IntArray(2)
    \\            host.getLocationOnScreen(location)
    \\            val screenBounds = Rect(node.x.toInt(), node.y.toInt(), (node.x + node.width).toInt(), (node.y + node.height).toInt())
    \\            info.setBoundsInScreen(Rect(screenBounds.left + location[0], screenBounds.top + location[1], screenBounds.right + location[0], screenBounds.bottom + location[1]))
    \\            return info
    \\        }
    \\
    \\        private fun performWidgetClick(id: Long): Boolean {
    \\            val node = widgetSemanticsById(id) ?: return false
    \\            return when {
    \\                widgetSupportsAction(node, WIDGET_ACTION_TOGGLE) -> dispatchWidgetAction(id, WIDGET_ACTION_KIND_TOGGLE)
    \\                widgetSupportsAction(node, WIDGET_ACTION_PRESS) -> dispatchWidgetAction(id, WIDGET_ACTION_KIND_PRESS)
    \\                widgetSupportsAction(node, WIDGET_ACTION_SELECT) -> dispatchWidgetAction(id, WIDGET_ACTION_KIND_SELECT)
    \\                else -> false
    \\            }
    \\        }
    \\
    \\        private fun setCollectionInfo(info: AccessibilityNodeInfo, node: WidgetSemantics, nodes: List<WidgetSemantics>) {
    \\            if (node.role == WIDGET_ROLE_GRID && node.gridRowCount >= 0 && node.gridColumnCount >= 0) {
    \\                info.setCollectionInfo(AccessibilityNodeInfo.CollectionInfo.obtain(node.gridRowCount.toInt(), node.gridColumnCount.toInt(), false))
    \\            } else if (node.role == WIDGET_ROLE_LIST) {
    \\                val childCount = nodes.count { it.parentId == node.id && it.role == WIDGET_ROLE_LISTITEM }
    \\                val itemCount = if (node.listItemCount >= 0) node.listItemCount.toInt() else childCount
    \\                if (itemCount > 0) info.setCollectionInfo(AccessibilityNodeInfo.CollectionInfo.obtain(itemCount, 1, false))
    \\            }
    \\        }
    \\
    \\        private fun setCollectionItemInfo(info: AccessibilityNodeInfo, node: WidgetSemantics) {
    \\            if (node.gridRowIndex >= 0 && node.gridColumnIndex >= 0) {
    \\                info.setCollectionItemInfo(AccessibilityNodeInfo.CollectionItemInfo.obtain(node.gridRowIndex.toInt(), 1, node.gridColumnIndex.toInt(), 1, false, info.isSelected))
    \\            } else if (node.listItemIndex >= 0) {
    \\                info.setCollectionItemInfo(AccessibilityNodeInfo.CollectionItemInfo.obtain(node.listItemIndex.toInt(), 1, 0, 1, false, info.isSelected))
    \\            }
    \\        }
    \\
    \\        private fun boundsInParent(node: WidgetSemantics, parent: WidgetSemantics?): Rect {
    \\            val parentX = parent?.x ?: 0f
    \\            val parentY = parent?.y ?: 0f
    \\            return Rect(
    \\                (node.x - parentX).toInt(),
    \\                (node.y - parentY).toInt(),
    \\                (node.x - parentX + node.width).toInt(),
    \\                (node.y - parentY + node.height).toInt(),
    \\            )
    \\        }
    \\
    \\        private fun widgetValueSelected(node: WidgetSemantics): Boolean {
    \\            return node.value != null && node.value >= 0.5f
    \\        }
    \\
    \\        private fun widgetStateDescription(node: WidgetSemantics): String? {
    \\            val states = ArrayList<String>()
    \\            if ((node.flags and WIDGET_FLAG_EXPANDED) != 0) states.add("Expanded")
    \\            if ((node.flags and WIDGET_FLAG_COLLAPSED) != 0) states.add("Collapsed")
    \\            if ((node.flags and WIDGET_FLAG_REQUIRED) != 0) states.add("Required")
    \\            if ((node.flags and WIDGET_FLAG_READ_ONLY) != 0) states.add("Read only")
    \\            if ((node.flags and WIDGET_FLAG_INVALID) != 0) states.add("Invalid")
    \\            return if (states.isEmpty()) null else states.joinToString(", ")
    \\        }
    \\
    \\        private fun sendVirtualEvent(id: Long, type: Int) {
    \\            val event = AccessibilityEvent.obtain(type)
    \\            event.setSource(host, id.toInt())
    \\            event.packageName = packageName
    \\            host.parent?.requestSendAccessibilityEvent(host, event)
    \\        }
    \\
    \\        private fun widgetAccessibilityClassName(node: WidgetSemantics): String {
    \\            return when (node.role) {
    \\                WIDGET_ROLE_BUTTON, WIDGET_ROLE_MENUITEM -> "android.widget.Button"
    \\                WIDGET_ROLE_TEXTBOX -> "android.widget.EditText"
    \\                WIDGET_ROLE_CHECKBOX -> "android.widget.CheckBox"
    \\                WIDGET_ROLE_SWITCH -> "android.widget.Switch"
    \\                WIDGET_ROLE_SLIDER -> "android.widget.SeekBar"
    \\                WIDGET_ROLE_PROGRESSBAR -> "android.widget.ProgressBar"
    \\                WIDGET_ROLE_IMAGE -> "android.widget.ImageView"
    \\                WIDGET_ROLE_LIST -> "android.widget.ListView"
    \\                else -> "android.view.View"
    \\            }
    \\        }
    \\
    \\        private fun widgetSupportsAction(node: WidgetSemantics, action: Int): Boolean {
    \\            return (node.actions and action) != 0
    \\        }
    \\
    \\        private fun widgetSupportsAnyAction(node: WidgetSemantics, actions: Int): Boolean {
    \\            return (node.actions and actions) != 0
    \\        }
    \\    }
    \\
    \\    override fun onCreate(savedInstanceState: Bundle?) {
    \\        super.onCreate(savedInstanceState)
    \\        System.loadLibrary("zero_native_host")
    \\
    \\        widgetSurface = WidgetSurfaceView()
    \\        widgetSurface.holder.addCallback(this)
    \\
    \\        val header = LinearLayout(this).apply {
    \\            orientation = LinearLayout.VERTICAL
    \\            setBackgroundColor(Color.rgb(245, 246, 248))
    \\            setPadding(32, 28, 32, 24)
    \\        }
    \\        val title = TextView(this).apply {
    \\            text = ZeroNativeShellConfig.title
    \\            textSize = 24f
    \\            setTextColor(Color.rgb(24, 24, 27))
    \\        }
    \\        statusLabel = TextView(this).apply {
    \\            text = ZeroNativeShellConfig.status
    \\            textSize = 13f
    \\            setTextColor(Color.rgb(95, 102, 114))
    \\            setPadding(0, 8, 0, 0)
    \\        }
    \\        val actions = LinearLayout(this).apply {
    \\            orientation = LinearLayout.HORIZONTAL
    \\            setPadding(0, 12, 0, 0)
    \\        }
    \\        val back = Button(this).apply {
    \\            text = ZeroNativeShellConfig.primaryButtonTitle
    \\            setOnClickListener { dispatchNativeCommand(ZeroNativeShellConfig.primaryCommand) }
    \\        }
    \\        val refresh = Button(this).apply {
    \\            text = ZeroNativeShellConfig.secondaryButtonTitle
    \\            setOnClickListener { dispatchNativeCommand(ZeroNativeShellConfig.secondaryCommand) }
    \\        }
    \\        actions.addView(back, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    \\        actions.addView(refresh, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    \\        header.addView(title)
    \\        header.addView(statusLabel)
    \\        header.addView(actions)
    \\
    \\        val webView = WebView(this).apply {
    \\            settings.javaScriptEnabled = false
    \\            loadWorkspace(this)
    \\        }
    \\        val content = FrameLayout(this)
    \\        content.addView(widgetSurface, FrameLayout.LayoutParams(
    \\            FrameLayout.LayoutParams.MATCH_PARENT,
    \\            FrameLayout.LayoutParams.MATCH_PARENT,
    \\        ))
    \\        content.addView(webView, FrameLayout.LayoutParams(
    \\            FrameLayout.LayoutParams.MATCH_PARENT,
    \\            FrameLayout.LayoutParams.MATCH_PARENT,
    \\        ))
    \\        val root = LinearLayout(this).apply {
    \\            orientation = LinearLayout.VERTICAL
    \\            setBackgroundColor(Color.WHITE)
    \\        }
    \\        root.addView(header, LinearLayout.LayoutParams(
    \\            LinearLayout.LayoutParams.MATCH_PARENT,
    \\            LinearLayout.LayoutParams.WRAP_CONTENT,
    \\        ))
    \\        root.addView(content, LinearLayout.LayoutParams(
    \\            LinearLayout.LayoutParams.MATCH_PARENT,
    \\            0,
    \\            1f,
    \\        ))
    \\        setContentView(root)
    \\
    \\        nativeApp = nativeCreate()
    \\        nativeSetAssetRoot(nativeApp, packagedAssetRoot())
    \\        nativeSetAssetEntry(nativeApp, ZeroNativeShellConfig.assetEntryPath)
    \\        nativeStart(nativeApp)
    \\        refreshWidgetSemanticsStatus()
    \\    }
    \\
    \\    private fun packagedAssetRoot(): String {
    \\        return if (ZeroNativeShellConfig.assetRootSubdirectory.isEmpty()) {
    \\            "android_asset/zero-native"
    \\        } else {
    \\            "android_asset/zero-native/${ZeroNativeShellConfig.assetRootSubdirectory}"
    \\        }
    \\    }
    \\
    \\    private fun packagedAssetEntry(): String {
    \\        return if (ZeroNativeShellConfig.assetRootSubdirectory.isEmpty()) {
    \\            "zero-native/${ZeroNativeShellConfig.assetEntryPath}"
    \\        } else {
    \\            "zero-native/${ZeroNativeShellConfig.assetRootSubdirectory}/${ZeroNativeShellConfig.assetEntryPath}"
    \\        }
    \\    }
    \\
    \\    private fun loadWorkspace(webView: WebView) {
    \\        val assetPath = packagedAssetEntry()
    \\        try {
    \\            assets.open(assetPath).close()
    \\            val url = Uri.Builder().scheme("file").path("/android_asset/$assetPath").build().toString()
    \\            webView.loadUrl(url)
    \\        } catch (_: Exception) {
    \\            webView.loadDataWithBaseURL(null, html, "text/html", "UTF-8", null)
    \\        }
    \\    }
    \\
    \\    private fun dispatchNativeCommand(command: String) {
    \\        if (nativeApp == 0L) return
    \\        val count = nativeCommand(nativeApp, command)
    \\        if (::statusLabel.isInitialized) {
    \\            statusLabel.text = "Command $count: $command"
    \\        }
    \\        nativeFrame(nativeApp)
    \\        refreshWidgetSemanticsStatus()
    \\    }
    \\
    \\    override fun onResume() {
    \\        super.onResume()
    \\        if (nativeApp != 0L) nativeActivate(nativeApp)
    \\    }
    \\
    \\    override fun onPause() {
    \\        if (nativeApp != 0L) nativeDeactivate(nativeApp)
    \\        super.onPause()
    \\    }
    \\
    \\    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
    \\        if (nativeApp == 0L) return
    \\        currentSurfaceHolder = holder
    \\        sendViewport(width, height, holder.surface)
    \\        nativeFrame(nativeApp)
    \\        refreshWidgetSemanticsStatus()
    \\    }
    \\
    \\    override fun surfaceCreated(holder: SurfaceHolder) {}
    \\
    \\    override fun surfaceDestroyed(holder: SurfaceHolder) {
    \\        if (currentSurfaceHolder == holder) currentSurfaceHolder = null
    \\    }
    \\
    \\    override fun onConfigurationChanged(newConfig: Configuration) {
    \\        super.onConfigurationChanged(newConfig)
    \\        if (nativeApp != 0L) {
    \\            nativeFrame(nativeApp)
    \\            refreshWidgetSemanticsStatus()
    \\        }
    \\    }
    \\
    \\    private fun widgetSemanticsSnapshot(): List<WidgetSemantics> {
    \\        if (nativeApp == 0L) return emptyList()
    \\        val count = nativeWidgetSemanticsCount(nativeApp)
    \\        val items = mutableListOf<WidgetSemantics>()
    \\        for (index in 0 until count) {
    \\            widgetSemanticsAt(index)?.let { items.add(it) }
    \\        }
    \\        return items
    \\    }
    \\
    \\    private fun widgetSemanticsAt(index: Int): WidgetSemantics? {
    \\        val ids = LongArray(12)
    \\        val ints = IntArray(5)
    \\        val floats = FloatArray(8)
    \\        if (!nativeWidgetSemanticsFields(nativeApp, index, ids, ints, floats)) return null
    \\        return widgetSemanticsFromNative(
    \\            ids,
    \\            ints,
    \\            floats,
    \\            String(nativeWidgetSemanticsLabel(nativeApp, index), Charsets.UTF_8),
    \\            String(nativeWidgetSemanticsText(nativeApp, index), Charsets.UTF_8),
    \\            String(nativeWidgetSemanticsPlaceholder(nativeApp, index), Charsets.UTF_8),
    \\        )
    \\    }
    \\
    \\    private fun widgetSemanticsById(id: Long): WidgetSemantics? {
    \\        val ids = LongArray(12)
    \\        val ints = IntArray(5)
    \\        val floats = FloatArray(8)
    \\        if (!nativeWidgetSemanticsByIdFields(nativeApp, id, ids, ints, floats)) return null
    \\        return widgetSemanticsFromNative(
    \\            ids,
    \\            ints,
    \\            floats,
    \\            String(nativeWidgetSemanticsByIdLabel(nativeApp, id), Charsets.UTF_8),
    \\            String(nativeWidgetSemanticsByIdText(nativeApp, id), Charsets.UTF_8),
    \\            String(nativeWidgetSemanticsByIdPlaceholder(nativeApp, id), Charsets.UTF_8),
    \\        )
    \\    }
    \\
    \\    private fun widgetSemanticsFromNative(ids: LongArray, ints: IntArray, floats: FloatArray, label: String, text: String, placeholder: String): WidgetSemantics {
    \\        return WidgetSemantics(
    \\            id = ids[0],
    \\            parentId = ids[1],
    \\            role = ints[0],
    \\            flags = ints[1],
    \\            actions = ints[2],
    \\            x = floats[0],
    \\            y = floats[1],
    \\            width = floats[2],
    \\            height = floats[3],
    \\            value = if (ints[3] != 0) floats[4] else null,
    \\            label = label,
    \\            text = text,
    \\            placeholder = placeholder,
    \\            textSelectionStart = ids[2],
    \\            textSelectionEnd = ids[3],
    \\            textCompositionStart = ids[4],
    \\            textCompositionEnd = ids[5],
    \\            gridRowIndex = ids[6],
    \\            gridColumnIndex = ids[7],
    \\            gridRowCount = ids[8],
    \\            gridColumnCount = ids[9],
    \\            listItemIndex = ids[10],
    \\            listItemCount = ids[11],
    \\            scrollOffset = floats[5],
    \\            scrollViewportExtent = floats[6],
    \\            scrollContentExtent = floats[7],
    \\            hasScroll = ints[4] != 0,
    \\        )
    \\    }
    \\
    \\    private fun widgetTextGeometry(id: Long): WidgetTextGeometry? {
    \\        val ints = IntArray(5)
    \\        val floats = FloatArray(12)
    \\        if (!nativeWidgetTextGeometry(nativeApp, id, ints, floats)) return null
    \\        return WidgetTextGeometry(
    \\            id = id,
    \\            hasCaretBounds = ints[0] != 0,
    \\            caretX = floats[0],
    \\            caretY = floats[1],
    \\            caretWidth = floats[2],
    \\            caretHeight = floats[3],
    \\            hasSelectionBounds = ints[1] != 0,
    \\            selectionX = floats[4],
    \\            selectionY = floats[5],
    \\            selectionWidth = floats[6],
    \\            selectionHeight = floats[7],
    \\            selectionRectCount = ints[2],
    \\            hasCompositionBounds = ints[3] != 0,
    \\            compositionX = floats[8],
    \\            compositionY = floats[9],
    \\            compositionWidth = floats[10],
    \\            compositionHeight = floats[11],
    \\            compositionRectCount = ints[4],
    \\        )
    \\    }
    \\
    \\    private fun dispatchWidgetAction(
    \\        id: Long,
    \\        action: Int,
    \\        text: String? = null,
    \\        selectionAnchor: Long = 0,
    \\        selectionFocus: Long = 0,
    \\        hasSelection: Boolean = false,
    \\    ): Boolean {
    \\        if (nativeApp == 0L) return false
    \\        val ok = nativeWidgetAction(nativeApp, id, action, text, selectionAnchor, selectionFocus, hasSelection)
    \\        if (ok) {
    \\            nativeFrame(nativeApp)
    \\            refreshWidgetSemanticsStatus()
    \\        }
    \\        return ok
    \\    }
    \\
    \\    private fun refreshWidgetSemanticsStatus() {
    \\        if (nativeApp == 0L || !::statusLabel.isInitialized) return
    \\        statusLabel.contentDescription = "Accessible items: ${widgetSemanticsSnapshot().size}"
    \\        if (::widgetSurface.isInitialized) widgetSurface.notifyWidgetSemanticsChanged()
    \\    }
    \\
    \\    private fun sendViewport(width: Int, height: Int, surface: Any) {
    \\        if (nativeApp == 0L) return
    \\        val density = resources.displayMetrics.density
    \\        val insets = window.decorView.rootWindowInsets
    \\        val safeTop = ((insets?.systemWindowInsetTop ?: 0).toFloat()) / density
    \\        val safeRight = ((insets?.systemWindowInsetRight ?: 0).toFloat()) / density
    \\        val safeBottom = ((insets?.systemWindowInsetBottom ?: 0).toFloat()) / density
    \\        val safeLeft = ((insets?.systemWindowInsetLeft ?: 0).toFloat()) / density
    \\        nativeViewport(nativeApp, width.toFloat(), height.toFloat(), density, surface, safeTop, safeRight, safeBottom, safeLeft, 0f, 0f, keyboardBottomInset(density), 0f)
    \\    }
    \\
    \\    private fun keyboardBottomInset(density: Float): Float {
    \\        val visibleFrame = Rect()
    \\        window.decorView.getWindowVisibleDisplayFrame(visibleFrame)
    \\        val hiddenBottom = (window.decorView.rootView.height - visibleFrame.bottom).coerceAtLeast(0)
    \\        return if (hiddenBottom > (100 * density).toInt()) hiddenBottom.toFloat() / density else 0f
    \\    }
    \\
    \\    override fun onTouchEvent(event: MotionEvent): Boolean {
    \\        if (nativeApp == 0L || event.pointerCount == 0) return false
    \\        val pointerId = event.getPointerId(0).toLong()
    \\        val x = event.x
    \\        val y = event.y
    \\        when (event.actionMasked) {
    \\            MotionEvent.ACTION_DOWN -> {
    \\                lastTouchX = x
    \\                lastTouchY = y
    \\                lastTouchActive = true
    \\                nativeTouch(nativeApp, pointerId, event.actionMasked, x, y, event.pressure)
    \\            }
    \\            MotionEvent.ACTION_MOVE -> {
    \\                if (lastTouchActive) nativeScroll(nativeApp, pointerId, x, y, lastTouchX - x, lastTouchY - y)
    \\                lastTouchX = x
    \\                lastTouchY = y
    \\                nativeTouch(nativeApp, pointerId, event.actionMasked, x, y, event.pressure)
    \\            }
    \\            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
    \\                lastTouchActive = false
    \\                nativeTouch(nativeApp, pointerId, event.actionMasked, x, y, event.pressure)
    \\            }
    \\            else -> nativeTouch(nativeApp, pointerId, event.actionMasked, x, y, event.pressure)
    \\        }
    \\        nativeFrame(nativeApp)
    \\        return true
    \\    }
    \\
    \\    override fun onBackPressed() {
    \\        if (nativeApp != 0L) {
    \\            dispatchNativeCommand(ZeroNativeShellConfig.primaryCommand)
    \\            return
    \\        }
    \\        super.onBackPressed()
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
    \\    external fun nativeActivate(app: Long)
    \\    external fun nativeDeactivate(app: Long)
    \\    external fun nativeStop(app: Long)
    \\    external fun nativeSetAssetRoot(app: Long, path: String)
    \\    external fun nativeSetAssetEntry(app: Long, path: String)
    \\    external fun nativeResize(app: Long, width: Float, height: Float, scale: Float, surface: Any)
    \\    external fun nativeViewport(app: Long, width: Float, height: Float, scale: Float, surface: Any, safeTop: Float, safeRight: Float, safeBottom: Float, safeLeft: Float, keyboardTop: Float, keyboardRight: Float, keyboardBottom: Float, keyboardLeft: Float)
    \\    external fun nativeTouch(app: Long, id: Long, phase: Int, x: Float, y: Float, pressure: Float)
    \\    external fun nativeScroll(app: Long, id: Long, x: Float, y: Float, deltaX: Float, deltaY: Float)
    \\    external fun nativeKey(app: Long, phase: Int, key: String, text: String, modifiers: Int)
    \\    external fun nativeText(app: Long, text: String)
    \\    external fun nativeIme(app: Long, kind: Int, text: String, cursor: Long)
    \\    external fun nativeCommand(app: Long, command: String): Int
    \\    external fun nativeFrame(app: Long)
    \\    external fun nativeGpuFrameState(app: Long, longs: LongArray, ints: IntArray, floats: FloatArray): Boolean
    \\    external fun nativeWidgetSemanticsCount(app: Long): Int
    \\    external fun nativeWidgetSemanticsFields(app: Long, index: Int, ids: LongArray, ints: IntArray, floats: FloatArray): Boolean
    \\    external fun nativeWidgetSemanticsLabel(app: Long, index: Int): ByteArray
    \\    external fun nativeWidgetSemanticsText(app: Long, index: Int): ByteArray
    \\    external fun nativeWidgetSemanticsPlaceholder(app: Long, index: Int): ByteArray
    \\    external fun nativeWidgetSemanticsByIdFields(app: Long, id: Long, ids: LongArray, ints: IntArray, floats: FloatArray): Boolean
    \\    external fun nativeWidgetSemanticsByIdLabel(app: Long, id: Long): ByteArray
    \\    external fun nativeWidgetSemanticsByIdText(app: Long, id: Long): ByteArray
    \\    external fun nativeWidgetSemanticsByIdPlaceholder(app: Long, id: Long): ByteArray
    \\    external fun nativeWidgetTextGeometry(app: Long, id: Long, ints: IntArray, floats: FloatArray): Boolean
    \\    external fun nativeWidgetAction(app: Long, id: Long, action: Int, text: String?, selectionAnchor: Long, selectionFocus: Long, hasSelection: Boolean): Boolean
    \\
    \\    companion object {
    \\        private const val WIDGET_ROLE_BUTTON = 4
    \\        private const val WIDGET_ROLE_TEXTBOX = 5
    \\        private const val WIDGET_ROLE_MENUITEM = 9
    \\        private const val WIDGET_ROLE_LIST = 10
    \\        private const val WIDGET_ROLE_LISTITEM = 11
    \\        private const val WIDGET_ROLE_GRID = 13
    \\        private const val WIDGET_ROLE_IMAGE = 3
    \\        private const val WIDGET_ROLE_CHECKBOX = 16
    \\        private const val WIDGET_ROLE_SWITCH = 17
    \\        private const val WIDGET_ROLE_SLIDER = 18
    \\        private const val WIDGET_ROLE_PROGRESSBAR = 19
    \\        private const val WIDGET_FLAG_FOCUSED = 1 shl 0
    \\        private const val WIDGET_FLAG_SELECTED = 1 shl 3
    \\        private const val WIDGET_FLAG_DISABLED = 1 shl 4
    \\        private const val WIDGET_FLAG_FOCUSABLE = 1 shl 5
    \\        private const val WIDGET_FLAG_EXPANDED = 1 shl 6
    \\        private const val WIDGET_FLAG_COLLAPSED = 1 shl 7
    \\        private const val WIDGET_FLAG_REQUIRED = 1 shl 8
    \\        private const val WIDGET_FLAG_READ_ONLY = 1 shl 9
    \\        private const val WIDGET_FLAG_INVALID = 1 shl 10
    \\        private const val WIDGET_ACTION_FOCUS = 1 shl 0
    \\        private const val WIDGET_ACTION_PRESS = 1 shl 1
    \\        private const val WIDGET_ACTION_TOGGLE = 1 shl 2
    \\        private const val WIDGET_ACTION_INCREMENT = 1 shl 3
    \\        private const val WIDGET_ACTION_DECREMENT = 1 shl 4
    \\        private const val WIDGET_ACTION_SET_TEXT = 1 shl 5
    \\        private const val WIDGET_ACTION_SET_SELECTION = 1 shl 6
    \\        private const val WIDGET_ACTION_SELECT = 1 shl 7
    \\        private const val WIDGET_ACTION_DISMISS = 1 shl 10
    \\        private const val WIDGET_ACTION_KIND_FOCUS = 0
    \\        private const val WIDGET_ACTION_KIND_PRESS = 1
    \\        private const val WIDGET_ACTION_KIND_TOGGLE = 2
    \\        private const val WIDGET_ACTION_KIND_INCREMENT = 3
    \\        private const val WIDGET_ACTION_KIND_DECREMENT = 4
    \\        private const val WIDGET_ACTION_KIND_SET_TEXT = 5
    \\        private const val WIDGET_ACTION_KIND_SET_SELECTION = 6
    \\        private const val WIDGET_ACTION_KIND_SELECT = 10
    \\        private const val WIDGET_ACTION_KIND_DISMISS = 13
    \\        private const val html = """
    \\            <!doctype html>
    \\            <meta name="viewport" content="width=device-width, initial-scale=1">
    \\            <body style="margin:0;font-family:system-ui,sans-serif;background:#f7f8fa;color:#18181b">
    \\              <main style="padding:28px 22px;display:grid;gap:16px">
    \\                <h1 style="margin:0;font-size:30px">Workspace</h1>
    \\                <p style="margin:0;color:#5f6672;line-height:1.5">This content is rendered by Android WebView while the header remains native Android UI.</p>
    \\              </main>
    \\            </body>
    \\        """
    \\    }
    \\}
    \\
    ;
}

fn androidJni() []const u8 {
    return
    \\#include <jni.h>
    \\#include <stdint.h>
    \\#include <string.h>
    \\#include "zero_native.h"
    \\static jbyteArray zero_native_jni_bytes(JNIEnv *env, const char *ptr, uintptr_t len) { jbyteArray out = (*env)->NewByteArray(env, (jsize)len); if (!out) return NULL; if (ptr && len > 0) (*env)->SetByteArrayRegion(env, out, 0, (jsize)len, (const jbyte*)ptr); return out; }
    \\JNIEXPORT jlong JNICALL Java_dev_zero_1native_MainActivity_nativeCreate(JNIEnv *env, jobject self) { (void)env; (void)self; return (jlong)zero_native_app_create(); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeDestroy(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_destroy((void*)app); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeStart(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_start((void*)app); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeActivate(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_activate((void*)app); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeDeactivate(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_deactivate((void*)app); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeStop(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_stop((void*)app); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeSetAssetRoot(JNIEnv *env, jobject self, jlong app, jstring path) { (void)self; const char *chars = (*env)->GetStringUTFChars(env, path, NULL); if (!chars) return; zero_native_app_set_asset_root((void*)app, chars, strlen(chars)); (*env)->ReleaseStringUTFChars(env, path, chars); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeSetAssetEntry(JNIEnv *env, jobject self, jlong app, jstring path) { (void)self; const char *chars = (*env)->GetStringUTFChars(env, path, NULL); if (!chars) return; zero_native_app_set_asset_entry((void*)app, chars, strlen(chars)); (*env)->ReleaseStringUTFChars(env, path, chars); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeResize(JNIEnv *env, jobject self, jlong app, jfloat w, jfloat h, jfloat scale, jobject surface) { (void)env; (void)self; zero_native_app_resize((void*)app, w, h, scale, surface); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeViewport(JNIEnv *env, jobject self, jlong app, jfloat w, jfloat h, jfloat scale, jobject surface, jfloat safe_top, jfloat safe_right, jfloat safe_bottom, jfloat safe_left, jfloat keyboard_top, jfloat keyboard_right, jfloat keyboard_bottom, jfloat keyboard_left) { (void)env; (void)self; zero_native_app_viewport((void*)app, w, h, scale, surface, safe_top, safe_right, safe_bottom, safe_left, keyboard_top, keyboard_right, keyboard_bottom, keyboard_left); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeTouch(JNIEnv *env, jobject self, jlong app, jlong id, jint phase, jfloat x, jfloat y, jfloat pressure) { (void)env; (void)self; zero_native_app_touch((void*)app, (uint64_t)id, phase, x, y, pressure); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeScroll(JNIEnv *env, jobject self, jlong app, jlong id, jfloat x, jfloat y, jfloat delta_x, jfloat delta_y) { (void)env; (void)self; zero_native_app_scroll((void*)app, (uint64_t)id, x, y, delta_x, delta_y); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeKey(JNIEnv *env, jobject self, jlong app, jint phase, jstring key, jstring text, jint modifiers) { (void)self; const char *key_chars = key ? (*env)->GetStringUTFChars(env, key, NULL) : NULL; const char *text_chars = text ? (*env)->GetStringUTFChars(env, text, NULL) : NULL; zero_native_app_key((void*)app, phase, key_chars, key_chars ? strlen(key_chars) : 0, text_chars, text_chars ? strlen(text_chars) : 0, (uint32_t)modifiers); if (key_chars) (*env)->ReleaseStringUTFChars(env, key, key_chars); if (text_chars) (*env)->ReleaseStringUTFChars(env, text, text_chars); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeText(JNIEnv *env, jobject self, jlong app, jstring text) { (void)self; const char *chars = (*env)->GetStringUTFChars(env, text, NULL); if (!chars) return; zero_native_app_text((void*)app, chars, strlen(chars)); (*env)->ReleaseStringUTFChars(env, text, chars); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeIme(JNIEnv *env, jobject self, jlong app, jint kind, jstring text, jlong cursor) { (void)self; const char *chars = text ? (*env)->GetStringUTFChars(env, text, NULL) : NULL; zero_native_app_ime((void*)app, kind, chars, chars ? strlen(chars) : 0, (intptr_t)cursor); if (chars) (*env)->ReleaseStringUTFChars(env, text, chars); }
    \\JNIEXPORT jint JNICALL Java_dev_zero_1native_MainActivity_nativeCommand(JNIEnv *env, jobject self, jlong app, jstring command) { (void)self; const char *chars = (*env)->GetStringUTFChars(env, command, NULL); if (!chars) return 0; zero_native_app_command((void*)app, chars, strlen(chars)); (*env)->ReleaseStringUTFChars(env, command, chars); return (jint)zero_native_app_last_command_count((void*)app); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeFrame(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_frame((void*)app); }
    \\JNIEXPORT jboolean JNICALL Java_dev_zero_1native_MainActivity_nativeGpuFrameState(JNIEnv *env, jobject self, jlong app, jlongArray longs, jintArray ints, jfloatArray floats) { (void)self; if (!longs || !ints || !floats) return JNI_FALSE; if ((*env)->GetArrayLength(env, longs) < 19 || (*env)->GetArrayLength(env, ints) < 9 || (*env)->GetArrayLength(env, floats) < 3) return JNI_FALSE; zero_native_gpu_frame_state_t state; memset(&state, 0, sizeof(state)); if (!zero_native_app_gpu_frame_state((void*)app, &state)) return JNI_FALSE; const jlong long_values[19] = { (jlong)state.surface_id, (jlong)state.window_id, (jlong)state.frame_index, (jlong)state.timestamp_ns, (jlong)state.frame_interval_ns, (jlong)state.input_timestamp_ns, (jlong)state.input_latency_ns, (jlong)state.input_latency_budget_ns, (jlong)state.input_latency_budget_exceeded_count, (jlong)state.first_frame_latency_ns, (jlong)state.first_frame_latency_budget_ns, (jlong)state.first_frame_latency_budget_exceeded_count, (jlong)state.canvas_revision, (jlong)state.canvas_command_count, (jlong)state.canvas_frame_batch_count, (jlong)state.canvas_frame_budget_exceeded_count, (jlong)state.widget_revision, (jlong)state.widget_node_count, (jlong)state.widget_semantics_count }; const jint int_values[9] = { (jint)state.input_latency_budget_ok, (jint)state.first_frame_latency_budget_ok, (jint)state.nonblank, (jint)state.sample_color, (jint)state.status, (jint)state.vsync, (jint)state.canvas_frame_requires_render, (jint)state.canvas_frame_full_repaint, (jint)state.canvas_frame_budget_ok }; const jfloat float_values[3] = { (jfloat)state.width, (jfloat)state.height, (jfloat)state.scale }; (*env)->SetLongArrayRegion(env, longs, 0, 19, long_values); (*env)->SetIntArrayRegion(env, ints, 0, 9, int_values); (*env)->SetFloatArrayRegion(env, floats, 0, 3, float_values); return JNI_TRUE; }
    \\JNIEXPORT jint JNICALL Java_dev_zero_1native_MainActivity_nativeWidgetSemanticsCount(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; return (jint)zero_native_app_widget_semantics_count((void*)app); }
    \\JNIEXPORT jboolean JNICALL Java_dev_zero_1native_MainActivity_nativeWidgetSemanticsFields(JNIEnv *env, jobject self, jlong app, jint index, jlongArray ids, jintArray ints, jfloatArray floats) { (void)self; if (!ids || !ints || !floats) return JNI_FALSE; if ((*env)->GetArrayLength(env, ids) < 12 || (*env)->GetArrayLength(env, ints) < 5 || (*env)->GetArrayLength(env, floats) < 8) return JNI_FALSE; zero_native_widget_semantics_t node; memset(&node, 0, sizeof(node)); if (!zero_native_app_widget_semantics_at((void*)app, (uintptr_t)index, &node)) return JNI_FALSE; const jlong id_values[12] = { (jlong)node.id, (jlong)node.parent_id, (jlong)node.text_selection_start, (jlong)node.text_selection_end, (jlong)node.text_composition_start, (jlong)node.text_composition_end, (jlong)node.grid_row_index, (jlong)node.grid_column_index, (jlong)node.grid_row_count, (jlong)node.grid_column_count, (jlong)node.list_item_index, (jlong)node.list_item_count }; const jint int_values[5] = { (jint)node.role, (jint)node.flags, (jint)node.actions, (jint)node.has_value, (jint)node.has_scroll }; const jfloat float_values[8] = { (jfloat)node.x, (jfloat)node.y, (jfloat)node.width, (jfloat)node.height, (jfloat)node.value, (jfloat)node.scroll_offset, (jfloat)node.scroll_viewport_extent, (jfloat)node.scroll_content_extent }; (*env)->SetLongArrayRegion(env, ids, 0, 12, id_values); (*env)->SetIntArrayRegion(env, ints, 0, 5, int_values); (*env)->SetFloatArrayRegion(env, floats, 0, 8, float_values); return JNI_TRUE; }
    \\JNIEXPORT jbyteArray JNICALL Java_dev_zero_1native_MainActivity_nativeWidgetSemanticsLabel(JNIEnv *env, jobject self, jlong app, jint index) { (void)self; zero_native_widget_semantics_t node; memset(&node, 0, sizeof(node)); if (!zero_native_app_widget_semantics_at((void*)app, (uintptr_t)index, &node)) return zero_native_jni_bytes(env, "", 0); return zero_native_jni_bytes(env, node.label, node.label_len); }
    \\JNIEXPORT jbyteArray JNICALL Java_dev_zero_1native_MainActivity_nativeWidgetSemanticsText(JNIEnv *env, jobject self, jlong app, jint index) { (void)self; zero_native_widget_semantics_t node; memset(&node, 0, sizeof(node)); if (!zero_native_app_widget_semantics_at((void*)app, (uintptr_t)index, &node)) return zero_native_jni_bytes(env, "", 0); return zero_native_jni_bytes(env, node.text, node.text_len); }
    \\JNIEXPORT jbyteArray JNICALL Java_dev_zero_1native_MainActivity_nativeWidgetSemanticsPlaceholder(JNIEnv *env, jobject self, jlong app, jint index) { (void)self; zero_native_widget_semantics_t node; memset(&node, 0, sizeof(node)); if (!zero_native_app_widget_semantics_at((void*)app, (uintptr_t)index, &node)) return zero_native_jni_bytes(env, "", 0); return zero_native_jni_bytes(env, node.placeholder, node.placeholder_len); }
    \\JNIEXPORT jboolean JNICALL Java_dev_zero_1native_MainActivity_nativeWidgetSemanticsByIdFields(JNIEnv *env, jobject self, jlong app, jlong id, jlongArray ids, jintArray ints, jfloatArray floats) { (void)self; if (!ids || !ints || !floats) return JNI_FALSE; if ((*env)->GetArrayLength(env, ids) < 12 || (*env)->GetArrayLength(env, ints) < 5 || (*env)->GetArrayLength(env, floats) < 8) return JNI_FALSE; zero_native_widget_semantics_t node; memset(&node, 0, sizeof(node)); if (!zero_native_app_widget_semantics_by_id((void*)app, (uint64_t)id, &node)) return JNI_FALSE; const jlong id_values[12] = { (jlong)node.id, (jlong)node.parent_id, (jlong)node.text_selection_start, (jlong)node.text_selection_end, (jlong)node.text_composition_start, (jlong)node.text_composition_end, (jlong)node.grid_row_index, (jlong)node.grid_column_index, (jlong)node.grid_row_count, (jlong)node.grid_column_count, (jlong)node.list_item_index, (jlong)node.list_item_count }; const jint int_values[5] = { (jint)node.role, (jint)node.flags, (jint)node.actions, (jint)node.has_value, (jint)node.has_scroll }; const jfloat float_values[8] = { (jfloat)node.x, (jfloat)node.y, (jfloat)node.width, (jfloat)node.height, (jfloat)node.value, (jfloat)node.scroll_offset, (jfloat)node.scroll_viewport_extent, (jfloat)node.scroll_content_extent }; (*env)->SetLongArrayRegion(env, ids, 0, 12, id_values); (*env)->SetIntArrayRegion(env, ints, 0, 5, int_values); (*env)->SetFloatArrayRegion(env, floats, 0, 8, float_values); return JNI_TRUE; }
    \\JNIEXPORT jbyteArray JNICALL Java_dev_zero_1native_MainActivity_nativeWidgetSemanticsByIdLabel(JNIEnv *env, jobject self, jlong app, jlong id) { (void)self; zero_native_widget_semantics_t node; memset(&node, 0, sizeof(node)); if (!zero_native_app_widget_semantics_by_id((void*)app, (uint64_t)id, &node)) return zero_native_jni_bytes(env, "", 0); return zero_native_jni_bytes(env, node.label, node.label_len); }
    \\JNIEXPORT jbyteArray JNICALL Java_dev_zero_1native_MainActivity_nativeWidgetSemanticsByIdText(JNIEnv *env, jobject self, jlong app, jlong id) { (void)self; zero_native_widget_semantics_t node; memset(&node, 0, sizeof(node)); if (!zero_native_app_widget_semantics_by_id((void*)app, (uint64_t)id, &node)) return zero_native_jni_bytes(env, "", 0); return zero_native_jni_bytes(env, node.text, node.text_len); }
    \\JNIEXPORT jbyteArray JNICALL Java_dev_zero_1native_MainActivity_nativeWidgetSemanticsByIdPlaceholder(JNIEnv *env, jobject self, jlong app, jlong id) { (void)self; zero_native_widget_semantics_t node; memset(&node, 0, sizeof(node)); if (!zero_native_app_widget_semantics_by_id((void*)app, (uint64_t)id, &node)) return zero_native_jni_bytes(env, "", 0); return zero_native_jni_bytes(env, node.placeholder, node.placeholder_len); }
    \\JNIEXPORT jboolean JNICALL Java_dev_zero_1native_MainActivity_nativeWidgetTextGeometry(JNIEnv *env, jobject self, jlong app, jlong id, jintArray ints, jfloatArray floats) { (void)self; if (!ints || !floats) return JNI_FALSE; if ((*env)->GetArrayLength(env, ints) < 5 || (*env)->GetArrayLength(env, floats) < 12) return JNI_FALSE; zero_native_widget_text_geometry_t geometry; memset(&geometry, 0, sizeof(geometry)); if (!zero_native_app_widget_text_geometry((void*)app, (uint64_t)id, &geometry)) return JNI_FALSE; const jint int_values[5] = { (jint)geometry.has_caret_bounds, (jint)geometry.has_selection_bounds, (jint)geometry.selection_rect_count, (jint)geometry.has_composition_bounds, (jint)geometry.composition_rect_count }; const jfloat float_values[12] = { (jfloat)geometry.caret_x, (jfloat)geometry.caret_y, (jfloat)geometry.caret_width, (jfloat)geometry.caret_height, (jfloat)geometry.selection_x, (jfloat)geometry.selection_y, (jfloat)geometry.selection_width, (jfloat)geometry.selection_height, (jfloat)geometry.composition_x, (jfloat)geometry.composition_y, (jfloat)geometry.composition_width, (jfloat)geometry.composition_height }; (*env)->SetIntArrayRegion(env, ints, 0, 5, int_values); (*env)->SetFloatArrayRegion(env, floats, 0, 12, float_values); return JNI_TRUE; }
    \\JNIEXPORT jboolean JNICALL Java_dev_zero_1native_MainActivity_nativeWidgetAction(JNIEnv *env, jobject self, jlong app, jlong id, jint action, jstring text, jlong selection_anchor, jlong selection_focus, jboolean has_selection) { (void)self; const char *chars = text ? (*env)->GetStringUTFChars(env, text, NULL) : NULL; zero_native_widget_action_t request; memset(&request, 0, sizeof(request)); request.id = (uint64_t)id; request.action = (int)action; request.text = chars; request.text_len = chars ? strlen(chars) : 0; request.selection_anchor = (uintptr_t)selection_anchor; request.selection_focus = (uintptr_t)selection_focus; request.has_selection = has_selection ? 1 : 0; const int ok = zero_native_app_widget_action((void*)app, &request); if (chars) (*env)->ReleaseStringUTFChars(env, text, chars); return ok ? JNI_TRUE : JNI_FALSE; }
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
    try copyMacosResourceIcon(allocator, io, package_dir, options.metadata.icons[0], "configured app icon");
}

fn copyMacosDocumentIcons(allocator: std.mem.Allocator, io: std.Io, package_dir: std.Io.Dir, metadata: manifest_tool.Metadata) !void {
    for (metadata.file_associations) |association| {
        const icon_path = association.icon orelse continue;
        try copyMacosResourceIcon(allocator, io, package_dir, icon_path, "configured document icon");
    }
}

fn copyMacosResourceIcon(allocator: std.mem.Allocator, io: std.Io, package_dir: std.Io.Dir, icon_path: []const u8, missing_label: []const u8) !void {
    const dest = try std.fmt.allocPrint(allocator, "Contents/Resources/{s}", .{std.fs.path.basename(icon_path)});
    defer allocator.free(dest);
    const icon_bytes = readPath(allocator, io, icon_path) catch |err| switch (err) {
        error.FileNotFound => {
            const placeholder = try std.fmt.allocPrint(allocator, "placeholder: {s} was not found; replace with a real macOS .icns before distributing\n", .{missing_label});
            defer allocator.free(placeholder);
            try writeFile(package_dir, io, dest, placeholder);
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

fn desktopExecArgumentAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            0...0x1f => return error.InvalidName,
            '"', '\\', '`', '$' => {
                try out.append(allocator, '\\');
                try out.append(allocator, ch);
            },
            '%' => try out.appendSlice(allocator, "%%"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
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
    _ = allocator;
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), source_path, dir, dest_subpath, io, .{ .make_path = true, .replace = true });
}

fn makeExecutable(dir: std.Io.Dir, io: std.Io, subpath: []const u8) !void {
    if (!std.Io.File.Permissions.has_executable_bit) return;

    var file = try dir.openFile(io, subpath, .{});
    defer file.close(io);
    const current_mode = (try file.stat(io)).permissions.toMode();
    const execute_if_readable = (current_mode & 0o444) >> 2;
    try file.setPermissions(io, .fromMode(current_mode | execute_if_readable));
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

fn hasRegistrationMetadata(metadata: manifest_tool.Metadata) bool {
    return metadata.file_associations.len > 0 or metadata.url_schemes.len > 0;
}

fn appendFmt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime format: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn trimExtensionDot(extension: []const u8) []const u8 {
    if (extension.len > 0 and extension[0] == '.') return extension[1..];
    return extension;
}

fn macosDocumentTypes(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]const u8 {
    if (metadata.file_associations.len == 0) return allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\  <key>CFBundleDocumentTypes</key>
        \\  <array>
        \\
    );
    for (metadata.file_associations) |association| {
        const name = try xmlEscapeAlloc(allocator, association.name);
        defer allocator.free(name);
        try appendFmt(allocator, &out,
            \\    <dict>
            \\      <key>CFBundleTypeName</key>
            \\      <string>{s}</string>
            \\      <key>CFBundleTypeRole</key>
            \\      <string>{s}</string>
            \\
        , .{ name, macosAssociationRole(association.role) });
        if (association.icon) |icon_path| {
            const icon = try xmlEscapeAlloc(allocator, std.fs.path.basename(icon_path));
            defer allocator.free(icon);
            try appendFmt(allocator, &out,
                \\      <key>CFBundleTypeIconFile</key>
                \\      <string>{s}</string>
                \\
            , .{icon});
        }
        if (association.extensions.len > 0) {
            try out.appendSlice(allocator,
                \\      <key>CFBundleTypeExtensions</key>
                \\      <array>
                \\
            );
            for (association.extensions) |extension| {
                const escaped = try xmlEscapeAlloc(allocator, trimExtensionDot(extension));
                defer allocator.free(escaped);
                try appendFmt(allocator, &out,
                    \\        <string>{s}</string>
                    \\
                , .{escaped});
            }
            try out.appendSlice(allocator,
                \\      </array>
                \\
            );
        }
        if (association.mime_types.len > 0) {
            try out.appendSlice(allocator,
                \\      <key>CFBundleTypeMIMETypes</key>
                \\      <array>
                \\
            );
            for (association.mime_types) |mime_type| {
                const escaped = try xmlEscapeAlloc(allocator, mime_type);
                defer allocator.free(escaped);
                try appendFmt(allocator, &out,
                    \\        <string>{s}</string>
                    \\
                , .{escaped});
            }
            try out.appendSlice(allocator,
                \\      </array>
                \\
            );
        }
        try out.appendSlice(allocator,
            \\    </dict>
            \\
        );
    }
    try out.appendSlice(allocator,
        \\  </array>
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn macosUrlTypes(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]const u8 {
    if (metadata.url_schemes.len == 0) return allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\  <key>CFBundleURLTypes</key>
        \\  <array>
        \\
    );
    for (metadata.url_schemes) |url_scheme| {
        const name_value = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ metadata.id, url_scheme.scheme });
        defer allocator.free(name_value);
        const name = try xmlEscapeAlloc(allocator, name_value);
        defer allocator.free(name);
        const scheme = try xmlEscapeAlloc(allocator, url_scheme.scheme);
        defer allocator.free(scheme);
        try appendFmt(allocator, &out,
            \\    <dict>
            \\      <key>CFBundleTypeRole</key>
            \\      <string>{s}</string>
            \\      <key>CFBundleURLName</key>
            \\      <string>{s}</string>
            \\      <key>CFBundleURLSchemes</key>
            \\      <array>
            \\        <string>{s}</string>
            \\      </array>
            \\    </dict>
            \\
        , .{ macosAssociationRole(url_scheme.role), name, scheme });
    }
    try out.appendSlice(allocator,
        \\  </array>
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn macosAssociationRole(role: []const u8) []const u8 {
    if (std.mem.eql(u8, role, "editor")) return "Editor";
    if (std.mem.eql(u8, role, "shell")) return "Shell";
    if (std.mem.eql(u8, role, "none")) return "None";
    return "Viewer";
}

fn linuxDesktopEntry(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]const u8 {
    const display_name = try desktopEntryEscapeAlloc(allocator, metadata.displayName());
    defer allocator.free(display_name);
    const executable = try desktopExecArgumentAlloc(allocator, metadata.name);
    defer allocator.free(executable);
    const field_code: []const u8 = if (metadata.url_schemes.len > 0) " %U" else if (metadata.file_associations.len > 0) " %F" else "";
    const mime_line = try linuxDesktopMimeLine(allocator, metadata);
    defer allocator.free(mime_line);
    return std.fmt.allocPrint(allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name={s}
        \\Exec={s}{s}
        \\Icon=app-icon
        \\Categories=Utility;
        \\Comment={s} desktop application
        \\{s}
        \\
    , .{ display_name, executable, field_code, display_name, mime_line });
}

fn linuxDesktopMimeLine(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]const u8 {
    if (!hasRegistrationMetadata(metadata)) return allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "MimeType=");
    for (metadata.file_associations) |association| {
        if (association.mime_types.len > 0) {
            for (association.mime_types) |mime_type| {
                try out.appendSlice(allocator, mime_type);
                try out.append(allocator, ';');
            }
        } else {
            const generated = try linuxGeneratedMimeType(allocator, metadata, association);
            defer allocator.free(generated);
            try out.appendSlice(allocator, generated);
            try out.append(allocator, ';');
        }
    }
    for (metadata.url_schemes) |url_scheme| {
        try appendFmt(allocator, &out, "x-scheme-handler/{s};", .{url_scheme.scheme});
    }
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

fn linuxMimeInfo(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
        \\
    );
    for (metadata.file_associations) |association| {
        if (association.mime_types.len > 0) {
            for (association.mime_types) |mime_type| {
                try appendLinuxMimeType(allocator, &out, association, mime_type);
            }
        } else {
            const generated = try linuxGeneratedMimeType(allocator, metadata, association);
            defer allocator.free(generated);
            try appendLinuxMimeType(allocator, &out, association, generated);
        }
    }
    try out.appendSlice(allocator,
        \\</mime-info>
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn appendLinuxMimeType(allocator: std.mem.Allocator, out: *std.ArrayList(u8), association: manifest_tool.FileAssociationMetadata, mime_type: []const u8) !void {
    const escaped_type = try xmlEscapeAlloc(allocator, mime_type);
    defer allocator.free(escaped_type);
    const comment = try xmlEscapeAlloc(allocator, association.name);
    defer allocator.free(comment);
    try appendFmt(allocator, out,
        \\  <mime-type type="{s}">
        \\    <comment>{s}</comment>
        \\
    , .{ escaped_type, comment });
    for (association.extensions) |extension| {
        const pattern = try std.fmt.allocPrint(allocator, "*.{s}", .{trimExtensionDot(extension)});
        defer allocator.free(pattern);
        const escaped_pattern = try xmlEscapeAlloc(allocator, pattern);
        defer allocator.free(escaped_pattern);
        try appendFmt(allocator, out,
            \\    <glob pattern="{s}"/>
            \\
        , .{escaped_pattern});
    }
    try out.appendSlice(allocator,
        \\  </mime-type>
        \\
    );
}

fn linuxGeneratedMimeType(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata, association: manifest_tool.FileAssociationMetadata) ![]const u8 {
    const app = try slugComponentAlloc(allocator, metadata.name);
    defer allocator.free(app);
    const name = try slugComponentAlloc(allocator, association.name);
    defer allocator.free(name);
    return std.fmt.allocPrint(allocator, "application/x-{s}-{s}", .{ app, name });
}

fn windowsRegistrationScript(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata, executable_name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const executable_subpath = try std.fmt.allocPrint(allocator, "bin\\{s}", .{executable_name});
    defer allocator.free(executable_subpath);
    const executable_literal = try powerShellStringAlloc(allocator, executable_subpath);
    defer allocator.free(executable_literal);

    try appendFmt(allocator, &out,
        \\$ErrorActionPreference = "Stop"
        \\$AppRoot = Split-Path -Parent $PSScriptRoot
        \\$Exe = Join-Path $AppRoot {s}
        \\$OpenCommand = '"' + $Exe + '" "%1"'
        \\
        \\function Set-DefaultValue([string]$Key, [string]$Value) {{
        \\    & reg.exe add $Key /ve /d $Value /f | Out-Null
        \\}}
        \\
        \\function Set-NamedValue([string]$Key, [string]$Name, [string]$Value) {{
        \\    & reg.exe add $Key /v $Name /d $Value /f | Out-Null
        \\}}
        \\
    , .{executable_literal});

    for (metadata.file_associations) |association| {
        const prog_id = try windowsProgId(allocator, metadata, association);
        defer allocator.free(prog_id);
        const prog_key = try std.fmt.allocPrint(allocator, "HKCU\\Software\\Classes\\{s}", .{prog_id});
        defer allocator.free(prog_key);
        const prog_key_literal = try powerShellStringAlloc(allocator, prog_key);
        defer allocator.free(prog_key_literal);
        const prog_id_literal = try powerShellStringAlloc(allocator, prog_id);
        defer allocator.free(prog_id_literal);
        const name_literal = try powerShellStringAlloc(allocator, association.name);
        defer allocator.free(name_literal);

        for (association.extensions) |extension| {
            const extension_key = try std.fmt.allocPrint(allocator, "HKCU\\Software\\Classes\\.{s}", .{trimExtensionDot(extension)});
            defer allocator.free(extension_key);
            const extension_key_literal = try powerShellStringAlloc(allocator, extension_key);
            defer allocator.free(extension_key_literal);
            try appendFmt(allocator, &out, "Set-DefaultValue {s} {s}\n", .{ extension_key_literal, prog_id_literal });
        }

        try appendFmt(allocator, &out,
            \\Set-DefaultValue {s} {s}
            \\Set-NamedValue {s} 'FriendlyTypeName' {s}
            \\Set-DefaultValue '{s}\DefaultIcon' $Exe
            \\Set-DefaultValue '{s}\shell\open\command' $OpenCommand
            \\
        , .{ prog_key_literal, name_literal, prog_key_literal, name_literal, prog_key, prog_key });
    }

    for (metadata.url_schemes) |url_scheme| {
        const scheme_key = try std.fmt.allocPrint(allocator, "HKCU\\Software\\Classes\\{s}", .{url_scheme.scheme});
        defer allocator.free(scheme_key);
        const scheme_key_literal = try powerShellStringAlloc(allocator, scheme_key);
        defer allocator.free(scheme_key_literal);
        const description = try std.fmt.allocPrint(allocator, "URL:{s}", .{url_scheme.scheme});
        defer allocator.free(description);
        const description_literal = try powerShellStringAlloc(allocator, description);
        defer allocator.free(description_literal);
        try appendFmt(allocator, &out,
            \\Set-DefaultValue {s} {s}
            \\Set-NamedValue {s} 'URL Protocol' ''
            \\Set-DefaultValue '{s}\shell\open\command' $OpenCommand
            \\
        , .{ scheme_key_literal, description_literal, scheme_key_literal, scheme_key });
    }

    try out.appendSlice(allocator, "Write-Host \"Registered file associations and URL schemes for this user.\"\n");
    return out.toOwnedSlice(allocator);
}

fn windowsProgId(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata, association: manifest_tool.FileAssociationMetadata) ![]const u8 {
    const app = try windowsIdentifierComponentAlloc(allocator, metadata.id);
    defer allocator.free(app);
    const name = try windowsIdentifierComponentAlloc(allocator, association.name);
    defer allocator.free(name);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ app, name });
}

fn windowsIdentifierComponentAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |ch| {
        if (isAsciiAlphanumeric(ch) or ch == '.') {
            try out.append(allocator, ch);
        }
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "App");
    return out.toOwnedSlice(allocator);
}

fn powerShellStringAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |ch| {
        switch (ch) {
            '\'' => try out.appendSlice(allocator, "''"),
            0...8, 11...12, 14...0x1f => return error.InvalidName,
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn slugComponentAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var last_dash = false;
    for (value) |ch| {
        if (isAsciiAlphanumeric(ch)) {
            try out.append(allocator, toLowerAscii(ch));
            last_dash = false;
        } else if (!last_dash and out.items.len > 0) {
            try out.append(allocator, '-');
            last_dash = true;
        }
    }
    if (last_dash) out.items.len -= 1;
    if (out.items.len == 0) try out.appendSlice(allocator, "item");
    return out.toOwnedSlice(allocator);
}

fn isAsciiAlphanumeric(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9');
}

fn toLowerAscii(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + ('a' - 'A');
    return ch;
}

fn createArchive(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !?[]const u8 {
    const archive_path = try archivePath(allocator, options);
    errdefer allocator.free(archive_path);
    switch (options.target) {
        .ios, .android => {
            allocator.free(archive_path);
            return null;
        },
        .macos, .windows, .linux => {},
    }
    const archive_command_path = try absolutePathAlloc(allocator, io, archive_path);
    defer allocator.free(archive_command_path);

    const ok = switch (options.target) {
        .macos => runArchiveCommand(io, &.{ "hdiutil", "create", "-volname", options.metadata.displayName(), "-srcfolder", options.output_path, "-ov", "-format", "UDZO", archive_command_path }, null),
        .windows => runArchiveCommand(io, &.{ "zip", "-r", archive_command_path, "." }, options.output_path),
        .linux => runArchiveCommand(io, &.{ "tar", "czf", archive_command_path, "-C", options.output_path, "." }, null),
        .ios, .android => unreachable,
    };

    if (!ok) {
        std.debug.print("warning: archive creation failed for {s}\n", .{archive_path});
        allocator.free(archive_path);
        return null;
    }
    return archive_path;
}

fn absolutePathAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn runArchiveCommand(io: std.Io, argv: []const []const u8, cwd: ?[]const u8) bool {
    const child_cwd: std.process.Child.Cwd = if (cwd) |path| .{ .path = path } else .inherit;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = child_cwd,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
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

test "archive command reports nonzero exit" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(!runArchiveCommand(std.testing.io, &.{ "sh", "-c", "exit 7" }, null));
}

test "mobile package templates include native command shells" {
    const header = embedHeader();
    try std.testing.expect(std.mem.indexOf(u8, header, "zero_native_widget_semantics_t") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "const char *placeholder") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "zero_native_widget_text_geometry_t") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "zero_native_widget_action_t") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "zero_native_viewport_state_t") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "zero_native_gpu_frame_state_t") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "ZERO_NATIVE_GPU_SURFACE_STATUS_READY") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "ZERO_NATIVE_WIDGET_ROLE_TEXTBOX") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "ZERO_NATIVE_WIDGET_FLAG_EXPANDED") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "ZERO_NATIVE_WIDGET_FLAG_COLLAPSED") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "ZERO_NATIVE_WIDGET_FLAG_REQUIRED") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "ZERO_NATIVE_WIDGET_FLAG_READ_ONLY") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "ZERO_NATIVE_WIDGET_FLAG_INVALID") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "ZERO_NATIVE_WIDGET_ACTION_SET_SELECTION") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "ZERO_NATIVE_WIDGET_ACTION_KIND_SET_TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "ZERO_NATIVE_WIDGET_ACTION_DISMISS") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "ZERO_NATIVE_WIDGET_ACTION_KIND_DISMISS") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "zero_native_app_viewport_state") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "zero_native_app_gpu_frame_state") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "zero_native_app_scroll") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "zero_native_app_widget_semantics_count") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "zero_native_app_widget_semantics_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "zero_native_app_widget_semantics_by_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "zero_native_app_widget_text_geometry") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "zero_native_app_widget_action") != null);

    const ios_controller = iosViewController();
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "UIButton(type: .system)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "ZeroNativeShellConfig.primaryCommand") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "zero_native_app_command") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "zero_native_app_set_asset_root") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "zero_native_app_set_asset_entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "ZeroNativeShellConfig.assetEntryPath") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "accessibilityPerformEscape") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "dismissWidgetAccessibilityNode") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "ZERO_NATIVE_WIDGET_FLAG_EXPANDED") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "ZERO_NATIVE_WIDGET_FLAG_REQUIRED") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "states.joined(separator: \", \")") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "webView.loadFileURL") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "appendingPathComponent(\"Resources\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "keyboardWillChangeFrameNotification") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "zero_native_app_viewport") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "struct WidgetSemantics") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "let placeholder: String") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "accessibilityHint = node.placeholder") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "struct WidgetTextGeometry") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "zero_native_app_widget_semantics_count") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "zero_native_app_widget_semantics_by_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "zero_native_app_widget_text_geometry") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "zero_native_app_widget_action") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "WidgetAccessibilityElement(accessibilityContainer: webView") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "override func accessibilityActivate") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "ZERO_NATIVE_WIDGET_ACTION_KIND_INCREMENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "view.safeAreaInsets") != null);
    try std.testing.expect(std.mem.indexOf(u8, iosDefaultShellConfig(), "primaryCommand = \"mobile.back\"") != null);

    const android_gradle = androidBuildGradle();
    try std.testing.expect(std.mem.indexOf(u8, android_gradle, "org.jetbrains.kotlin.android") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_gradle, "externalNativeBuild") != null);

    const android_activity = androidActivity();
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "System.loadLibrary(\"zero_native_host\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "nativeSetAssetRoot(nativeApp, packagedAssetRoot())") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "ZeroNativeShellConfig.assetEntryPath") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "webView.loadUrl(url)") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "dispatchNativeCommand(ZeroNativeShellConfig.secondaryCommand)") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "WebView(this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "nativeViewport(nativeApp") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "nativeScroll(nativeApp") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "external fun nativeGpuFrameState") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "external fun nativeKey") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "external fun nativeText") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "external fun nativeIme") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "data class WidgetSemantics") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "val placeholder: String") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "info.hintText = node.placeholder") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "data class WidgetTextGeometry") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "nativeWidgetSemanticsFields") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "nativeWidgetSemanticsPlaceholder") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "nativeWidgetSemanticsByIdFields") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "nativeWidgetSemanticsByIdPlaceholder") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "nativeWidgetTextGeometry") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "nativeWidgetAction") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "AccessibilityNodeProvider") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "WidgetSurfaceView") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "createAccessibilityNodeInfo") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "performAction(virtualViewId") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "AccessibilityNodeInfo.ACTION_DISMISS") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "WIDGET_ACTION_KIND_DISMISS") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "widgetStateDescription(node)") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "WIDGET_FLAG_REQUIRED") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "WIDGET_FLAG_READ_ONLY") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "WIDGET_FLAG_INVALID") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "rootWindowInsets") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "keyboardBottomInset") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "if (currentSurfaceHolder == holder) currentSurfaceHolder = null") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "surfaceDestroyed(holder: SurfaceHolder) {\n        if (nativeApp != 0L) nativeStop(nativeApp)\n    }") == null);
    try std.testing.expect(std.mem.indexOf(u8, androidDefaultShellConfig(), "const val secondaryCommand = \"mobile.refresh\"") != null);

    const android_cmake = androidCMakeLists();
    try std.testing.expect(std.mem.indexOf(u8, android_cmake, "add_library(zero_native_host SHARED zero_native_jni.c)") != null);

    const android_jni = androidJni();
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "#include <stdint.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "zero_native_app_set_asset_root") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "zero_native_app_set_asset_entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "zero_native_app_viewport") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "zero_native_app_gpu_frame_state") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "zero_native_app_scroll") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "zero_native_app_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "zero_native_app_text") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "zero_native_app_ime") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "zero_native_app_widget_semantics_count") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "zero_native_app_widget_semantics_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "zero_native_app_widget_semantics_by_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "node.placeholder") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "zero_native_app_widget_text_geometry") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "zero_native_app_widget_action") != null);
}

test "android shell config escapes Kotlin string interpolation" {
    var model = defaultMobileShellModel();
    model.title = "Sales $HOME";
    model.status = "Total ${amount}";
    model.primary_button_title = "Back $1";

    const android_config = try androidShellConfigAlloc(std.testing.allocator, model);
    defer std.testing.allocator.free(android_config);
    try std.testing.expect(std.mem.indexOf(u8, android_config, "const val title = \"Sales \\$HOME\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_config, "const val status = \"Total \\${amount}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_config, "const val primaryButtonTitle = \"Back \\$1\"") != null);

    const ios_config = try iosShellConfigAlloc(std.testing.allocator, model);
    defer std.testing.allocator.free(ios_config);
    try std.testing.expect(std.mem.indexOf(u8, ios_config, "static let title = \"Sales $HOME\"") != null);
}

test "mobile skeletons create native library drop-in directories" {
    var cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(std.testing.io, ".zig-cache/test-package-mobile-skeletons");
    defer cwd.deleteTree(std.testing.io, ".zig-cache/test-package-mobile-skeletons") catch {};

    try cwd.createDirPath(std.testing.io, ".zig-cache/test-package-mobile-skeletons");
    _ = try createIosSkeleton(std.testing.io, ".zig-cache/test-package-mobile-skeletons/ios");
    _ = try createAndroidSkeleton(std.testing.io, ".zig-cache/test-package-mobile-skeletons/android");

    var ios_libs = try cwd.openDir(std.testing.io, ".zig-cache/test-package-mobile-skeletons/ios/Libraries", .{});
    ios_libs.close(std.testing.io);
    var ios_config = try cwd.openFile(std.testing.io, ".zig-cache/test-package-mobile-skeletons/ios/zero-nativeHost/ZeroNativeShellConfig.swift", .{});
    ios_config.close(std.testing.io);

    var android_libs = try cwd.openDir(std.testing.io, ".zig-cache/test-package-mobile-skeletons/android/app/src/main/cpp/lib", .{});
    android_libs.close(std.testing.io);
    var android_config = try cwd.openFile(std.testing.io, ".zig-cache/test-package-mobile-skeletons/android/app/src/main/java/dev/zero_native/ZeroNativeShellConfig.kt", .{});
    android_config.close(std.testing.io);

    var cmake = try cwd.openFile(std.testing.io, ".zig-cache/test-package-mobile-skeletons/android/app/src/main/cpp/CMakeLists.txt", .{});
    cmake.close(std.testing.io);

    var styles = try cwd.openFile(std.testing.io, ".zig-cache/test-package-mobile-skeletons/android/app/src/main/res/values/styles.xml", .{});
    styles.close(std.testing.io);
}

test "mobile package artifacts use manifest identity metadata" {
    var cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(std.testing.io, ".zig-cache/test-package-mobile-identity");
    defer cwd.deleteTree(std.testing.io, ".zig-cache/test-package-mobile-identity") catch {};
    try cwd.createDirPath(std.testing.io, ".zig-cache/test-package-mobile-identity/assets");
    try cwd.writeFile(std.testing.io, .{ .sub_path = ".zig-cache/test-package-mobile-identity/assets/main.html", .data = "<h1>Mobile</h1>" });

    const shell_views = [_]manifest_tool.ShellViewMetadata{
        .{ .label = "mobile-header", .kind = "toolbar", .edge = "top", .height = 104 },
        .{ .label = "mobile-title", .kind = "label", .parent = "mobile-header", .text = "Field Console" },
        .{ .label = "mobile-status", .kind = "statusbar", .edge = "bottom", .height = 28, .text = "Shell ready" },
        .{ .label = "mobile-back", .kind = "button", .parent = "mobile-header", .text = "Go Back", .command = "mobile.go_back" },
        .{ .label = "mobile-refresh", .kind = "button", .parent = "mobile-header", .text = "Sync Now", .command = "mobile.sync" },
        .{ .label = "workspace", .kind = "webview", .url = "zero://app/index.html", .fill = true },
    };
    const shell_windows = [_]manifest_tool.ShellWindowMetadata{.{
        .label = "main",
        .title = "Field Console",
        .views = &shell_views,
    }};
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.zero-native.mobile-app",
        .name = "mobile-demo",
        .display_name = "Mobile Demo",
        .version = "2.3.4",
        .frontend = .{ .dist = "dist", .entry = "main.html" },
        .shell = .{ .windows = &shell_windows },
    };

    const ios_stats = try createIosArtifact(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .output_path = ".zig-cache/test-package-mobile-identity/ios",
        .assets_dir = ".zig-cache/test-package-mobile-identity/assets",
        .frontend = metadata.frontend,
    });
    const android_stats = try createAndroidArtifact(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .output_path = ".zig-cache/test-package-mobile-identity/android",
        .assets_dir = ".zig-cache/test-package-mobile-identity/assets",
        .frontend = metadata.frontend,
    });
    try std.testing.expectEqual(@as(usize, 1), ios_stats.asset_count);
    try std.testing.expectEqual(@as(usize, 1), android_stats.asset_count);

    const plist = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/ios/Info.plist");
    defer std.testing.allocator.free(plist);
    try std.testing.expect(std.mem.indexOf(u8, plist, "dev.zero-native.mobile-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "Mobile Demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "2.3.4") != null);

    const gradle = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/android/app/build.gradle");
    defer std.testing.allocator.free(gradle);
    try std.testing.expect(std.mem.indexOf(u8, gradle, "applicationId \"dev.zero_native.mobile_app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, gradle, "namespace \"dev.zero_native.mobile_app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, gradle, "versionName \"2.3.4\"") != null);

    const manifest = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/android/app/src/main/AndroidManifest.xml");
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "android:label=\"Mobile Demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "android:name=\"dev.zero_native.MainActivity\"") != null);

    const ios_shell_config = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/ios/zero-nativeHost/ZeroNativeShellConfig.swift");
    defer std.testing.allocator.free(ios_shell_config);
    try std.testing.expect(std.mem.indexOf(u8, ios_shell_config, "static let title = \"Field Console\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_shell_config, "static let status = \"Shell ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_shell_config, "static let primaryCommand = \"mobile.go_back\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_shell_config, "static let secondaryButtonTitle = \"Sync Now\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_shell_config, "static let assetRootSubdirectory = \"dist\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_shell_config, "static let assetEntryPath = \"main.html\"") != null);
    const ios_controller = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/ios/zero-nativeHost/ZeroNativeHostViewController.swift");
    defer std.testing.allocator.free(ios_controller);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "zero_native_app_set_asset_entry") != null);

    const android_shell_config = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/android/app/src/main/java/dev/zero_native/ZeroNativeShellConfig.kt");
    defer std.testing.allocator.free(android_shell_config);
    try std.testing.expect(std.mem.indexOf(u8, android_shell_config, "const val title = \"Field Console\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_shell_config, "const val status = \"Shell ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_shell_config, "const val primaryButtonTitle = \"Go Back\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_shell_config, "const val secondaryCommand = \"mobile.sync\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_shell_config, "const val assetRootSubdirectory = \"dist\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_shell_config, "const val assetEntryPath = \"main.html\"") != null);
    const android_activity = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/android/app/src/main/java/dev/zero_native/MainActivity.kt");
    defer std.testing.allocator.free(android_activity);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "nativeSetAssetEntry(nativeApp, ZeroNativeShellConfig.assetEntryPath)") != null);

    const ios_asset = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/ios/Resources/dist/main.html");
    defer std.testing.allocator.free(ios_asset);
    try std.testing.expectEqualStrings("<h1>Mobile</h1>", ios_asset);

    const android_asset = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/android/app/src/main/assets/zero-native/dist/main.html");
    defer std.testing.allocator.free(android_asset);
    try std.testing.expectEqualStrings("<h1>Mobile</h1>", android_asset);
}

test "mobile packages allow chromium desktop engine metadata" {
    var cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(std.testing.io, ".zig-cache/test-package-mobile-chromium");
    defer cwd.deleteTree(std.testing.io, ".zig-cache/test-package-mobile-chromium") catch {};
    try cwd.createDirPath(std.testing.io, ".zig-cache/test-package-mobile-chromium/assets");
    try cwd.writeFile(std.testing.io, .{ .sub_path = ".zig-cache/test-package-mobile-chromium/assets/index.html", .data = "<h1>Mobile</h1>" });

    const metadata: manifest_tool.Metadata = .{
        .id = "dev.zero-native.mobile-chromium",
        .name = "mobile-chromium",
        .display_name = "Mobile Chromium",
        .version = "1.0.0",
        .frontend = .{ .dist = "dist", .entry = "index.html" },
    };

    const ios_stats = try createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .ios,
        .output_path = ".zig-cache/test-package-mobile-chromium/ios",
        .assets_dir = ".zig-cache/test-package-mobile-chromium/assets",
        .frontend = metadata.frontend,
        .web_engine = .chromium,
    });
    const android_stats = try createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .android,
        .output_path = ".zig-cache/test-package-mobile-chromium/android",
        .assets_dir = ".zig-cache/test-package-mobile-chromium/assets",
        .frontend = metadata.frontend,
        .web_engine = .chromium,
    });

    try std.testing.expectEqual(PackageTarget.ios, ios_stats.target);
    try std.testing.expectEqual(PackageTarget.android, android_stats.target);
    try std.testing.expectEqual(@as(usize, 1), ios_stats.asset_count);
    try std.testing.expectEqual(@as(usize, 1), android_stats.asset_count);
}

test "linux desktop entry contains app name" {
    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .display_name = "Demo App", .version = "1.2.3" };
    const entry = try linuxDesktopEntry(std.testing.allocator, metadata);
    defer std.testing.allocator.free(entry);
    try std.testing.expect(std.mem.indexOf(u8, entry, "Name=Demo App") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry, "Exec=\"demo\"") != null);
}

test "linux desktop metadata includes file associations and URL schemes" {
    const extensions = [_][]const u8{"md"};
    const associations = [_]manifest_tool.FileAssociationMetadata{.{
        .name = "Markdown Document",
        .extensions = &extensions,
    }};
    const schemes = [_]manifest_tool.UrlSchemeMetadata{.{ .scheme = "acme-notes" }};
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.app",
        .name = "demo",
        .display_name = "Demo App",
        .version = "1.2.3",
        .file_associations = &associations,
        .url_schemes = &schemes,
    };
    const entry = try linuxDesktopEntry(std.testing.allocator, metadata);
    defer std.testing.allocator.free(entry);
    try std.testing.expect(std.mem.indexOf(u8, entry, "Exec=\"demo\" %U") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry, "MimeType=application/x-demo-markdown-document;x-scheme-handler/acme-notes;") != null);

    const mime_info = try linuxMimeInfo(std.testing.allocator, metadata);
    defer std.testing.allocator.free(mime_info);
    try std.testing.expect(std.mem.indexOf(u8, mime_info, "<mime-type type=\"application/x-demo-markdown-document\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, mime_info, "<glob pattern=\"*.md\"/>") != null);
}

test "linux desktop entry quotes executable names with spaces" {
    const extensions = [_][]const u8{"txt"};
    const associations = [_]manifest_tool.FileAssociationMetadata{.{
        .name = "Text Document",
        .extensions = &extensions,
    }};
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.spaced",
        .name = "Example App",
        .version = "1.2.3",
        .file_associations = &associations,
    };
    const entry = try linuxDesktopEntry(std.testing.allocator, metadata);
    defer std.testing.allocator.free(entry);
    try std.testing.expect(std.mem.indexOf(u8, entry, "Exec=\"Example App\" %F") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, plist, "LSMinimumSystemVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "11.0") != null);
}

test "plist template includes document and URL registrations" {
    const extensions = [_][]const u8{ "md", ".markdown" };
    const mime_types = [_][]const u8{"text/markdown"};
    const associations = [_]manifest_tool.FileAssociationMetadata{.{
        .name = "Markdown Document",
        .role = "editor",
        .extensions = &extensions,
        .mime_types = &mime_types,
        .icon = "assets/markdown.icns",
    }};
    const schemes = [_]manifest_tool.UrlSchemeMetadata{.{ .scheme = "acme-notes" }};
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.app",
        .name = "demo",
        .display_name = "Demo App",
        .version = "1.2.3",
        .file_associations = &associations,
        .url_schemes = &schemes,
    };
    const plist = try macosInfoPlist(std.testing.allocator, metadata, "demo");
    defer std.testing.allocator.free(plist);
    try std.testing.expect(std.mem.indexOf(u8, plist, "CFBundleDocumentTypes") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "CFBundleTypeRole") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "Editor") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "markdown.icns") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<string>markdown</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "text/markdown") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "CFBundleURLTypes") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "acme-notes") != null);
}

test "macOS package copies document type icons into resources" {
    var cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(std.testing.io, ".zig-cache/test-package-doc-icons");
    defer cwd.deleteTree(std.testing.io, ".zig-cache/test-package-doc-icons") catch {};
    try cwd.createDirPath(std.testing.io, ".zig-cache/test-package-doc-icons/assets");
    try cwd.createDirPath(std.testing.io, ".zig-cache/test-package-doc-icons/doc-icons");
    try cwd.writeFile(std.testing.io, .{ .sub_path = ".zig-cache/test-package-doc-icons/doc-icons/markdown.icns", .data = "icnsdoc-icon" });

    const extensions = [_][]const u8{"md"};
    const associations = [_]manifest_tool.FileAssociationMetadata{.{
        .name = "Markdown Document",
        .extensions = &extensions,
        .icon = ".zig-cache/test-package-doc-icons/doc-icons/markdown.icns",
    }};
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.app",
        .name = "demo",
        .version = "1.2.3",
        .file_associations = &associations,
    };

    _ = try createMacosApp(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .output_path = ".zig-cache/test-package-doc-icons/Demo.app",
        .assets_dir = ".zig-cache/test-package-doc-icons/assets",
    });

    const copied = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-doc-icons/Demo.app/Contents/Resources/markdown.icns");
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("icnsdoc-icon", copied);
}

test "windows registration script contains extension and protocol keys" {
    const extensions = [_][]const u8{"md"};
    const associations = [_]manifest_tool.FileAssociationMetadata{.{
        .name = "Markdown Document",
        .extensions = &extensions,
    }};
    const schemes = [_]manifest_tool.UrlSchemeMetadata{.{ .scheme = "acme-notes" }};
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.app",
        .name = "demo",
        .version = "1.2.3",
        .file_associations = &associations,
        .url_schemes = &schemes,
    };
    const script = try windowsRegistrationScript(std.testing.allocator, metadata, "demo.exe");
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, "bin\\demo.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "HKCU\\Software\\Classes\\.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "dev.example.app.MarkdownDocument") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "HKCU\\Software\\Classes\\acme-notes") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "URL:acme-notes") != null);
}

test "copying files preserves executable permissions" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    var cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(std.testing.io, ".zig-cache/test-package-copy-mode");
    try cwd.createDirPath(std.testing.io, ".zig-cache/test-package-copy-mode/dest");
    defer cwd.deleteTree(std.testing.io, ".zig-cache/test-package-copy-mode") catch {};

    const source_path = ".zig-cache/test-package-copy-mode/source-bin";
    var source = try cwd.createFile(std.testing.io, source_path, .{ .permissions = .executable_file });
    try source.writeStreamingAll(std.testing.io, "test binary");
    source.close(std.testing.io);

    var dest_dir = try cwd.openDir(std.testing.io, ".zig-cache/test-package-copy-mode/dest", .{});
    defer dest_dir.close(std.testing.io);
    try copyFileToDir(std.testing.allocator, std.testing.io, dest_dir, source_path, "Contents/MacOS/app");

    var dest = try dest_dir.openFile(std.testing.io, "Contents/MacOS/app", .{});
    defer dest.close(std.testing.io);
    const dest_permissions = (try dest.stat(std.testing.io)).permissions;
    try std.testing.expect((dest_permissions.toMode() & 0o111) != 0);
}

test "macOS app executable is marked executable" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    var cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(std.testing.io, ".zig-cache/test-package-macos-mode");
    try cwd.createDirPath(std.testing.io, ".zig-cache/test-package-macos-mode/assets");
    defer cwd.deleteTree(std.testing.io, ".zig-cache/test-package-macos-mode") catch {};

    const source_path = ".zig-cache/test-package-macos-mode/source-bin";
    try cwd.writeFile(std.testing.io, .{ .sub_path = source_path, .data = "test binary" });

    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "mode-test", .version = "1.2.3" };
    _ = try createMacosApp(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .output_path = ".zig-cache/test-package-macos-mode/ModeTest.app",
        .binary_path = source_path,
        .assets_dir = ".zig-cache/test-package-macos-mode/assets",
    });

    var app_dir = try cwd.openDir(std.testing.io, ".zig-cache/test-package-macos-mode/ModeTest.app", .{});
    defer app_dir.close(std.testing.io);
    var executable = try app_dir.openFile(std.testing.io, "Contents/MacOS/mode-test", .{});
    defer executable.close(std.testing.io);
    const permissions = (try executable.stat(std.testing.io)).permissions;
    try std.testing.expect((permissions.toMode() & 0o111) != 0);
}

test "desktop chromium packages are rejected before CEF layout checks" {
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.demo",
        .name = "demo",
        .version = "0.1.0",
    };

    try std.testing.expectError(error.UnsupportedWebEngine, createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .linux,
        .output_path = ".zig-cache/test-package-linux-chromium",
        .web_engine = .chromium,
        .cef_dir = ".zig-cache/missing-linux-cef",
    }));
    try std.testing.expectError(error.UnsupportedWebEngine, createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .windows,
        .output_path = ".zig-cache/test-package-windows-chromium",
        .web_engine = .chromium,
        .cef_dir = ".zig-cache/missing-windows-cef",
    }));
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
