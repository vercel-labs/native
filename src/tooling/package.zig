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
    try writeFile(dir, io, "README.md", androidReadme());
    try writeFile(dir, io, "settings.gradle", "pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }\ndependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { google(); mavenCentral() } }\nrootProject.name = 'zero-nativeHost'\ninclude ':app'\n");
    try writeFile(dir, io, "app/build.gradle", androidBuildGradle());
    try writeFile(dir, io, "app/src/main/AndroidManifest.xml", androidManifest());
    try writeFile(dir, io, "app/src/main/java/dev/zero_native/MainActivity.kt", androidActivity());
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
    if (options.binary_path) |binary_path| try copyFileToDir(allocator, io, dir, binary_path, "Libraries/libzero-native.a");
    try writeReport(allocator, dir, io, "package-manifest.zon", options, "libzero-native.a", 0);
    return .{ .path = options.output_path, .artifact_name = std.fs.path.basename(options.output_path), .target = .ios, .web_engine = options.web_engine };
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
    \\void *zero_native_app_create(void);
    \\void zero_native_app_destroy(void *app);
    \\void zero_native_app_start(void *app);
    \\void zero_native_app_activate(void *app);
    \\void zero_native_app_deactivate(void *app);
    \\void zero_native_app_stop(void *app);
    \\void zero_native_app_resize(void *app, float width, float height, float scale, void *surface);
    \\void zero_native_app_touch(void *app, uint64_t id, int phase, float x, float y, float pressure);
    \\void zero_native_app_command(void *app, const char *name, uintptr_t len);
    \\void zero_native_app_frame(void *app);
    \\void zero_native_app_set_asset_root(void *app, const char *path, uintptr_t len);
    \\uintptr_t zero_native_app_last_command_count(void *app);
    \\const char *zero_native_app_last_command_name(void *app);
    \\const char *zero_native_app_last_error_name(void *app);
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
    \\            zero_native_app_start(nativeApp)
    \\        }
    \\        webView.loadHTMLString(Self.html, baseURL: nil)
    \\    }
    \\
    \\    private func configureHeader() {
    \\        headerView.backgroundColor = .secondarySystemBackground
    \\        titleLabel.text = "zero-native"
    \\        titleLabel.font = .preferredFont(forTextStyle: .title2)
    \\        titleLabel.adjustsFontForContentSizeCategory = true
    \\        statusLabel.text = "Native commands ready"
    \\        statusLabel.font = .preferredFont(forTextStyle: .caption1)
    \\        statusLabel.textColor = .secondaryLabel
    \\        backButton.setTitle("Back", for: .normal)
    \\        backButton.addTarget(self, action: #selector(sendBackCommand), for: .touchUpInside)
    \\        refreshButton.setTitle("Refresh", for: .normal)
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
    \\        dispatchNativeCommand("mobile.back")
    \\    }
    \\
    \\    @objc private func sendRefreshCommand() {
    \\        dispatchNativeCommand("mobile.refresh")
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
    \\    }
    \\
    \\    @objc private func keyboardFrameWillChange(_ notification: Notification) {
    \\        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
    \\        let keyboardFrame = view.convert(value.cgRectValue, from: nil)
    \\        webViewBottomConstraint?.constant = -max(0, view.bounds.maxY - keyboardFrame.minY)
    \\        view.layoutIfNeeded()
    \\    }
    \\
    \\    @objc private func keyboardWillHide(_ notification: Notification) {
    \\        _ = notification
    \\        webViewBottomConstraint?.constant = 0
    \\        view.layoutIfNeeded()
    \\    }
    \\
    \\    override func viewDidLayoutSubviews() {
    \\        super.viewDidLayoutSubviews()
    \\        guard let nativeApp else { return }
    \\        let scale = Float(view.window?.screen.scale ?? UIScreen.main.scale)
    \\        zero_native_app_resize(nativeApp, Float(webView.bounds.width), Float(webView.bounds.height), scale, nil)
    \\        zero_native_app_frame(nativeApp)
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
    return "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"><application android:theme=\"@style/AppTheme\"><activity android:name=\".MainActivity\" android:configChanges=\"keyboard|keyboardHidden|orientation|screenSize\" android:exported=\"true\" android:windowSoftInputMode=\"adjustResize\"><intent-filter><action android:name=\"android.intent.action.MAIN\"/><category android:name=\"android.intent.category.LAUNCHER\"/></intent-filter></activity></application></manifest>\n";
}

fn androidManifestForMetadata(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]const u8 {
    const label = try xmlEscapeAlloc(allocator, metadata.displayName());
    defer allocator.free(label);
    return std.fmt.allocPrint(allocator,
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android">
        \\  <application android:label="{s}" android:theme="@style/AppTheme">
        \\    <activity android:name=".MainActivity" android:configChanges="keyboard|keyboardHidden|orientation|screenSize" android:exported="true" android:windowSoftInputMode="adjustResize">
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

fn androidActivity() []const u8 {
    return
    \\package dev.zero_native
    \\
    \\import android.app.Activity
    \\import android.content.res.Configuration
    \\import android.graphics.Color
    \\import android.os.Bundle
    \\import android.view.MotionEvent
    \\import android.view.SurfaceHolder
    \\import android.view.SurfaceView
    \\import android.webkit.WebView
    \\import android.widget.Button
    \\import android.widget.FrameLayout
    \\import android.widget.LinearLayout
    \\import android.widget.TextView
    \\
    \\class MainActivity : Activity(), SurfaceHolder.Callback {
    \\    private var nativeApp: Long = 0
    \\    private lateinit var statusLabel: TextView
    \\
    \\    override fun onCreate(savedInstanceState: Bundle?) {
    \\        super.onCreate(savedInstanceState)
    \\        System.loadLibrary("zero_native_host")
    \\
    \\        val surface = SurfaceView(this)
    \\        surface.holder.addCallback(this)
    \\
    \\        val header = LinearLayout(this).apply {
    \\            orientation = LinearLayout.VERTICAL
    \\            setBackgroundColor(Color.rgb(245, 246, 248))
    \\            setPadding(32, 28, 32, 24)
    \\        }
    \\        val title = TextView(this).apply {
    \\            text = "zero-native"
    \\            textSize = 24f
    \\            setTextColor(Color.rgb(24, 24, 27))
    \\        }
    \\        statusLabel = TextView(this).apply {
    \\            text = "Native commands ready"
    \\            textSize = 13f
    \\            setTextColor(Color.rgb(95, 102, 114))
    \\            setPadding(0, 8, 0, 0)
    \\        }
    \\        val actions = LinearLayout(this).apply {
    \\            orientation = LinearLayout.HORIZONTAL
    \\            setPadding(0, 12, 0, 0)
    \\        }
    \\        val back = Button(this).apply {
    \\            text = "Back"
    \\            setOnClickListener { dispatchNativeCommand("mobile.back") }
    \\        }
    \\        val refresh = Button(this).apply {
    \\            text = "Refresh"
    \\            setOnClickListener { dispatchNativeCommand("mobile.refresh") }
    \\        }
    \\        actions.addView(back, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    \\        actions.addView(refresh, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    \\        header.addView(title)
    \\        header.addView(statusLabel)
    \\        header.addView(actions)
    \\
    \\        val webView = WebView(this).apply {
    \\            settings.javaScriptEnabled = false
    \\            loadDataWithBaseURL(null, html, "text/html", "UTF-8", null)
    \\        }
    \\        val content = FrameLayout(this)
    \\        content.addView(surface, FrameLayout.LayoutParams(
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
    \\        nativeStart(nativeApp)
    \\    }
    \\
    \\    private fun dispatchNativeCommand(command: String) {
    \\        if (nativeApp == 0L) return
    \\        val count = nativeCommand(nativeApp, command)
    \\        if (::statusLabel.isInitialized) {
    \\            statusLabel.text = "Command $count: $command"
    \\        }
    \\        nativeFrame(nativeApp)
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
    \\        nativeResize(nativeApp, width.toFloat(), height.toFloat(), resources.displayMetrics.density, holder.surface)
    \\        nativeFrame(nativeApp)
    \\    }
    \\
    \\    override fun surfaceCreated(holder: SurfaceHolder) {}
    \\
    \\    override fun surfaceDestroyed(holder: SurfaceHolder) {
    \\        if (nativeApp != 0L) nativeStop(nativeApp)
    \\    }
    \\
    \\    override fun onConfigurationChanged(newConfig: Configuration) {
    \\        super.onConfigurationChanged(newConfig)
    \\        if (nativeApp != 0L) nativeFrame(nativeApp)
    \\    }
    \\
    \\    override fun onTouchEvent(event: MotionEvent): Boolean {
    \\        if (nativeApp == 0L) return false
    \\        nativeTouch(nativeApp, event.getPointerId(0).toLong(), event.actionMasked, event.x, event.y, event.pressure)
    \\        nativeFrame(nativeApp)
    \\        return true
    \\    }
    \\
    \\    override fun onBackPressed() {
    \\        if (nativeApp != 0L) {
    \\            dispatchNativeCommand("mobile.back")
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
    \\    external fun nativeResize(app: Long, width: Float, height: Float, scale: Float, surface: Any)
    \\    external fun nativeTouch(app: Long, id: Long, phase: Int, x: Float, y: Float, pressure: Float)
    \\    external fun nativeCommand(app: Long, command: String): Int
    \\    external fun nativeFrame(app: Long)
    \\
    \\    companion object {
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
    \\JNIEXPORT jlong JNICALL Java_dev_zero_1native_MainActivity_nativeCreate(JNIEnv *env, jobject self) { (void)env; (void)self; return (jlong)zero_native_app_create(); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeDestroy(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_destroy((void*)app); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeStart(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_start((void*)app); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeActivate(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_activate((void*)app); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeDeactivate(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_deactivate((void*)app); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeStop(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_stop((void*)app); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeResize(JNIEnv *env, jobject self, jlong app, jfloat w, jfloat h, jfloat scale, jobject surface) { (void)env; (void)self; zero_native_app_resize((void*)app, w, h, scale, surface); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeTouch(JNIEnv *env, jobject self, jlong app, jlong id, jint phase, jfloat x, jfloat y, jfloat pressure) { (void)env; (void)self; zero_native_app_touch((void*)app, (uint64_t)id, phase, x, y, pressure); }
    \\JNIEXPORT jint JNICALL Java_dev_zero_1native_MainActivity_nativeCommand(JNIEnv *env, jobject self, jlong app, jstring command) { (void)self; const char *chars = (*env)->GetStringUTFChars(env, command, NULL); if (!chars) return 0; zero_native_app_command((void*)app, chars, strlen(chars)); (*env)->ReleaseStringUTFChars(env, command, chars); return (jint)zero_native_app_last_command_count((void*)app); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeFrame(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_frame((void*)app); }
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
    const executable = try desktopEntryEscapeAlloc(allocator, metadata.name);
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

test "mobile package templates include native command shells" {
    const ios_controller = iosViewController();
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "UIButton(type: .system)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "zero_native_app_command") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_controller, "keyboardWillChangeFrameNotification") != null);

    const android_gradle = androidBuildGradle();
    try std.testing.expect(std.mem.indexOf(u8, android_gradle, "org.jetbrains.kotlin.android") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_gradle, "externalNativeBuild") != null);

    const android_activity = androidActivity();
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "System.loadLibrary(\"zero_native_host\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "dispatchNativeCommand(\"mobile.refresh\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "WebView(this)") != null);

    const android_cmake = androidCMakeLists();
    try std.testing.expect(std.mem.indexOf(u8, android_cmake, "add_library(zero_native_host SHARED zero_native_jni.c)") != null);

    const android_jni = androidJni();
    try std.testing.expect(std.mem.indexOf(u8, android_jni, "#include <stdint.h>") != null);
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

    var android_libs = try cwd.openDir(std.testing.io, ".zig-cache/test-package-mobile-skeletons/android/app/src/main/cpp/lib", .{});
    android_libs.close(std.testing.io);

    var cmake = try cwd.openFile(std.testing.io, ".zig-cache/test-package-mobile-skeletons/android/app/src/main/cpp/CMakeLists.txt", .{});
    cmake.close(std.testing.io);
}

test "mobile package artifacts use manifest identity metadata" {
    var cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(std.testing.io, ".zig-cache/test-package-mobile-identity");
    defer cwd.deleteTree(std.testing.io, ".zig-cache/test-package-mobile-identity") catch {};

    const metadata: manifest_tool.Metadata = .{
        .id = "dev.zero-native.mobile-app",
        .name = "mobile-demo",
        .display_name = "Mobile Demo",
        .version = "2.3.4",
    };

    _ = try createIosArtifact(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .output_path = ".zig-cache/test-package-mobile-identity/ios",
    });
    _ = try createAndroidArtifact(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .output_path = ".zig-cache/test-package-mobile-identity/android",
    });

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
}

test "linux desktop entry contains app name" {
    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .display_name = "Demo App", .version = "1.2.3" };
    const entry = try linuxDesktopEntry(std.testing.allocator, metadata);
    defer std.testing.allocator.free(entry);
    try std.testing.expect(std.mem.indexOf(u8, entry, "Name=Demo App") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry, "Exec=demo") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, entry, "Exec=demo %U") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry, "MimeType=application/x-demo-markdown-document;x-scheme-handler/acme-notes;") != null);

    const mime_info = try linuxMimeInfo(std.testing.allocator, metadata);
    defer std.testing.allocator.free(mime_info);
    try std.testing.expect(std.mem.indexOf(u8, mime_info, "<mime-type type=\"application/x-demo-markdown-document\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, mime_info, "<glob pattern=\"*.md\"/>") != null);
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
