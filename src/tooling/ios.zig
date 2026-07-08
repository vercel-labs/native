//! The iOS host tier: the toolkit owns the entire iOS app.
//!
//! An app directory with app.zon + src/ never contains host code — the
//! UIKit host lives in the SDK (src/platform/ios/uikit_host.m, embedded
//! into the CLI below) and drives the app through the embed C ABI. Two
//! consumers:
//!
//! - `native dev --target ios`: build the embed static library for the
//!   simulator, assemble a minimal .app bundle around the toolkit host,
//!   install + launch it via `xcrun simctl`, and stream the app log.
//! - `native package --target ios` (package.zig): emit a complete Xcode
//!   project (xcodeproj.zig) around the same host sources and a
//!   device-slice library, archive-ready with zero edits.
//!
//! Everything app-specific flows from app.zon: bundle id (`id`), names
//! (`name`/`display_name`), version, and icons (the shared single-source
//! icon pipeline renders the asset catalog at package time).

const std = @import("std");
const builtin = @import("builtin");
const buildgraph = @import("buildgraph.zig");
const embedlib = @import("embedlib.zig");
const manifest_tool = @import("manifest.zig");
const process_tree = @import("process_tree.zig");
const toolchain = @import("toolchain.zig");

/// The toolkit-owned UIKit host application (canvas surface view,
/// touch/keyboard/IME forwarding, CoreText measurement, safe-area
/// viewport reporting) — the single source of truth compiled by both the
/// dev loop and the packaged Xcode project. The bytes arrive through the
/// `ios_host` module (src/platform/ios/files.zig).
pub const host_source = @import("ios_host").uikit_host_m;
pub const host_header = @import("ios_host").native_sdk_app_h;

pub const host_source_name = "uikit_host.m";
pub const host_header_name = "native_sdk_app.h";

pub const deployment_target = "15.0";

pub const Error = error{
    MissingManifest,
    MissingFramework,
    ZigBuildFailed,
    HostCompileFailed,
    SimulatorUnavailable,
    SimulatorCommandFailed,
};

/// Write the host sources into `dir_path` (created if needed).
pub fn writeHostSources(io: std.Io, dir_path: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = host_source_name, .data = host_source });
    try dir.writeFile(io, .{ .sub_path = host_header_name, .data = host_header });
}

/// The iOS bundle identifier for an app.zon `id`: underscores map to
/// hyphens because Apple's bundle-identifier grammar allows only
/// alphanumerics, hyphens, and periods (`xcodebuild archive` rejects the
/// rest) — the mirror of the Android packaging path, which maps hyphens
/// to underscores for Java package rules.
pub fn bundleIdAlloc(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, id);
    for (out) |*ch| {
        if (ch.* == '_') ch.* = '-';
    }
    return out;
}

/// The host-tier Info.plist: app identity from app.zon plus the fixed
/// UIKit application keys (full-screen launch via the modern
/// `UILaunchScreen` dictionary — without it iOS letterboxes the app and
/// safe-area insets lie). `NSAllowsLocalNetworking` scopes an App
/// Transport Security exception to localhost and the local network only —
/// the dev loop streams audio and other media from a server on the Mac —
/// while HTTPS stays required for everything on the internet.
pub fn infoPlistAlloc(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]u8 {
    const raw_bundle_id = try bundleIdAlloc(allocator, metadata.id);
    defer allocator.free(raw_bundle_id);
    const bundle_id = try xmlEscapeAlloc(allocator, raw_bundle_id);
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
        \\  <key>CFBundleDevelopmentRegion</key>
        \\  <string>en</string>
        \\  <key>CFBundleExecutable</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleInfoDictionaryVersion</key>
        \\  <string>6.0</string>
        \\  <key>CFBundleName</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleDisplayName</key>
        \\  <string>{s}</string>
        \\  <key>CFBundlePackageType</key>
        \\  <string>APPL</string>
        \\  <key>CFBundleShortVersionString</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleVersion</key>
        \\  <string>{s}</string>
        \\  <key>LSRequiresIPhoneOS</key>
        \\  <true/>
        \\  <key>MinimumOSVersion</key>
        \\  <string>
    ++ deployment_target ++
        \\</string>
        \\  <key>NSAppTransportSecurity</key>
        \\  <dict>
        \\    <key>NSAllowsLocalNetworking</key>
        \\    <true/>
        \\  </dict>
        \\  <key>UILaunchScreen</key>
        \\  <dict/>
        \\  <key>UISupportedInterfaceOrientations</key>
        \\  <array>
        \\    <string>UIInterfaceOrientationPortrait</string>
        \\    <string>UIInterfaceOrientationLandscapeLeft</string>
        \\    <string>UIInterfaceOrientationLandscapeRight</string>
        \\  </array>
        \\</dict>
        \\</plist>
        \\
    , .{ name, bundle_id, name, display_name, version, version });
}

pub const LibSlice = enum {
    simulator,
    device,

    /// Zig -Dtarget triple for this slice on the current host arch.
    pub fn zigTriple(self: LibSlice) []const u8 {
        return switch (self) {
            .simulator => if (builtin.cpu.arch == .x86_64) "x86_64-ios-simulator" else "aarch64-ios-simulator",
            .device => "aarch64-ios",
        };
    }

    /// Clang -target triple matching `zigTriple`.
    pub fn clangTriple(self: LibSlice) []const u8 {
        return switch (self) {
            .simulator => if (builtin.cpu.arch == .x86_64)
                "x86_64-apple-ios" ++ deployment_target ++ "-simulator"
            else
                "arm64-apple-ios" ++ deployment_target ++ "-simulator",
            .device => "arm64-apple-ios" ++ deployment_target,
        };
    }

    pub fn clangSdk(self: LibSlice) []const u8 {
        return switch (self) {
            .simulator => "iphonesimulator",
            .device => "iphoneos",
        };
    }
};

pub const LibBuildOptions = struct {
    base_env: *std.process.Environ.Map,
    assume_yes: bool = false,
    forwarded_args: []const []const u8 = &.{},
    slice: LibSlice,
    optimize: []const u8 = "Debug",
};

/// Build the app's embed static library via `zig build lib` (the step
/// `addApp`/`addMobileLib` register for mobile targets), synthesizing the
/// generated build graph for non-ejected apps exactly like `native
/// build`. Returns the installed library path, allocator-owned. Expects
/// the caller to have chdir'd into the app dir.
///
/// The install prefix is keyed by the slice's target triple
/// (.native/embed/<triple>): the simulator and device slices — and the
/// Android tier — all build the same `lib` step, and a single shared
/// destination let whichever slice built last own the bytes, so an
/// interleaved run for another target poisoned the next host link. A
/// private per-triple stage removes the collision; content freshness
/// within the stage is the compiler's content-addressed cache, never
/// wall-clock time.
pub fn buildEmbedLib(allocator: std.mem.Allocator, io: std.Io, app_name: []const u8, options: LibBuildOptions) ![]const u8 {
    const zig_exe = try toolchain.resolveZig(allocator, io, options.base_env, .{ .assume_yes = options.assume_yes });
    defer allocator.free(zig_exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ zig_exe, "build", "lib" });

    const ejected = buildgraph.fileExists(io, "build.zig");
    var build_file: ?[]const u8 = null;
    defer if (build_file) |path| allocator.free(path);
    if (!ejected) {
        const framework_root = try buildgraph.resolveFrameworkRoot(allocator, io, options.base_env) orelse {
            std.debug.print(
                \\cannot locate the Native SDK toolkit for this app.
                \\Set NATIVE_SDK_PATH to your SDK checkout, or run a
                \\`native` binary that lives inside one (zig-out/bin/native).
                \\
            , .{});
            return error.MissingFramework;
        };
        defer allocator.free(framework_root);
        build_file = try buildgraph.ensureGeneratedBuild(allocator, io, ".", .{
            .app_name = app_name,
            .framework_root = framework_root,
        });
        try argv.appendSlice(allocator, &.{ "--build-file", build_file.? });
    }

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    const prefix = try embedlib.prefixAlloc(allocator, cwd_path, options.slice.zigTriple());
    defer allocator.free(prefix);
    try argv.appendSlice(allocator, &.{ "--prefix", prefix });

    const target_flag = try std.fmt.allocPrint(allocator, "-Dtarget={s}", .{options.slice.zigTriple()});
    defer allocator.free(target_flag);
    try argv.append(allocator, target_flag);
    const optimize_flag = try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{options.optimize});
    defer allocator.free(optimize_flag);
    if (!hasOptimizeFlag(options.forwarded_args)) try argv.append(allocator, optimize_flag);
    try argv.appendSlice(allocator, options.forwarded_args);

    try runInherit(io, argv.items, error.ZigBuildFailed);

    const lib_path = try embedlib.libPathAlloc(allocator, options.slice.zigTriple(), app_name);
    errdefer allocator.free(lib_path);
    if (!buildgraph.fileExists(io, lib_path)) {
        std.debug.print("native: expected the embed library at {s} after `zig build lib` - the app build did not install it\n", .{lib_path});
        return error.ZigBuildFailed;
    }
    return lib_path;
}

pub const DevOptions = struct {
    base_env: *std.process.Environ.Map,
    assume_yes: bool = false,
    forwarded_args: []const []const u8 = &.{},
    /// Simulator device name or UDID (`--device`); picked automatically
    /// when unset (a booted device, else the first available iPhone).
    device: ?[]const u8 = null,
};

/// `native dev --target ios`: build for the simulator, install, launch,
/// and stream the app log until the app exits or Ctrl-C.
///
/// Markup fragment hot reload is not wired to the simulator yet: the
/// watcher polls source paths relative to the app process's working
/// directory through an Io the desktop runner supplies, and the embed
/// host supplies neither — edit + rerun is the loop today.
pub fn runDev(allocator: std.mem.Allocator, io: std.Io, options: DevOptions) !void {
    if (!buildgraph.fileExists(io, "app.zon")) {
        std.debug.print(
            \\no app.zon here — `native dev --target ios` runs inside an app directory
            \\(or pass one: `native dev path/to/app --target ios`). Start one with `native init`.
            \\
        , .{});
        return error.MissingManifest;
    }
    const metadata = try manifest_tool.readMetadata(allocator, io, "app.zon");
    const bundle_id = try bundleIdAlloc(allocator, metadata.id);
    defer allocator.free(bundle_id);

    std.debug.print("native dev (ios): building the embed library ({s}, Debug)\n", .{LibSlice.simulator.zigTriple()});
    const lib_path = try buildEmbedLib(allocator, io, metadata.name, .{
        .base_env = options.base_env,
        .assume_yes = options.assume_yes,
        .forwarded_args = options.forwarded_args,
        .slice = .simulator,
    });
    defer allocator.free(lib_path);

    // Assemble the .app bundle around the toolkit host.
    const bundle_path = try std.fmt.allocPrint(allocator, ".native/ios/{s}.app", .{metadata.name});
    defer allocator.free(bundle_path);
    const executable_path = try std.fs.path.join(allocator, &.{ bundle_path, metadata.name });
    defer allocator.free(executable_path);
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, bundle_path) catch {};
    try cwd.createDirPath(io, bundle_path);
    try writeHostSources(io, ".native/ios/host");

    const info_plist = try infoPlistAlloc(allocator, metadata);
    defer allocator.free(info_plist);
    {
        var bundle_dir = try cwd.openDir(io, bundle_path, .{});
        defer bundle_dir.close(io);
        try bundle_dir.writeFile(io, .{ .sub_path = "Info.plist", .data = info_plist });
    }

    std.debug.print("native dev (ios): compiling the toolkit UIKit host\n", .{});
    // Content gate before the link: a staged archive built for another
    // target (ELF from the Android tier) must fail here with the real
    // cause, not as a confusing linker error.
    embedlib.requireArchiveClass(allocator, io, lib_path, .macho, LibSlice.simulator.zigTriple()) catch return error.HostCompileFailed;
    try runInherit(io, &.{
        "xcrun",         "--sdk",        LibSlice.simulator.clangSdk(),
        "clang",         "-target",      LibSlice.simulator.clangTriple(),
        "-fobjc-arc",    "-O2",          ".native/ios/host/" ++ host_source_name,
        lib_path,        "-framework",   "UIKit",
        "-framework",    "Metal",        "-framework",
        "QuartzCore",    "-framework",   "Foundation",
        "-framework",    "CoreGraphics", "-framework",
        "AVFoundation",  "-framework",   "ImageIO",
        "-o",            executable_path,
    }, error.HostCompileFailed);
    try runInherit(io, &.{ "codesign", "--force", "--sign", "-", bundle_path }, error.HostCompileFailed);

    const device = options.device orelse try pickSimulatorDevice(allocator, io);
    const device_owned = options.device == null;
    defer if (device_owned) allocator.free(device);

    std.debug.print("native dev (ios): booting simulator \"{s}\"\n", .{device});
    // Idempotent boot: already-booted devices report an error we ignore.
    runQuiet(allocator, io, &.{ "xcrun", "simctl", "boot", device }) catch {};
    try runInherit(io, &.{ "xcrun", "simctl", "bootstatus", device, "-b" }, error.SimulatorCommandFailed);

    std.debug.print("native dev (ios): installing {s} ({s})\n", .{ bundle_path, bundle_id });
    try runInherit(io, &.{ "xcrun", "simctl", "install", device, bundle_path }, error.SimulatorCommandFailed);
    runQuiet(allocator, io, &.{ "xcrun", "simctl", "terminate", device, bundle_id }) catch {};

    std.debug.print(
        \\native dev (ios): launching {s} — streaming the app log (Ctrl-C stops it).
        \\  markup hot reload does not reach the simulator yet: edit, then rerun `native dev --target ios`.
        \\
    , .{bundle_id});
    // --console-pty attaches the app's output to this terminal and keeps
    // the command alive for the app's lifetime — the log stream. The
    // child gets its own process group so Ctrl-C/kill of the CLI also
    // stops the attached session (the simulator app itself is terminated
    // on the next dev run's `simctl terminate`).
    var launch_child = try std.process.spawn(io, .{
        .argv = &.{ "xcrun", "simctl", "launch", "--console-pty", device, bundle_id },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .pgid = process_tree.spawnPgid(),
    });
    const launch_group: i32 = process_tree.groupId(&launch_child);
    if (launch_group > 0) process_tree.own(launch_group);
    defer if (launch_group > 0) process_tree.releaseAndKill(launch_group);
    _ = try launch_child.wait(io);
}

/// Pick a simulator device: a booted one wins, else the first available
/// iPhone (booted on demand by the caller).
pub fn pickSimulatorDevice(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "xcrun", "simctl", "list", "devices", "available" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch {
        std.debug.print("native dev (ios): `xcrun simctl` is unavailable - install Xcode and its iOS simulator runtime\n", .{});
        return error.SimulatorUnavailable;
    };
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("native dev (ios): `xcrun simctl list` failed - install Xcode and its iOS simulator runtime\n", .{});
        return error.SimulatorUnavailable;
    }

    if (parseSimulatorDeviceList(result.stdout)) |name| {
        return allocator.dupe(u8, name);
    }
    std.debug.print(
        \\native dev (ios): no available iPhone simulator found.
        \\Install an iOS simulator runtime in Xcode, or pass one explicitly:
        \\  native dev --target ios --device "iPhone 16 Pro"
        \\
    , .{});
    return error.SimulatorUnavailable;
}

/// `simctl list devices available` lines look like
/// `    iPhone 16 Pro (UDID) (Booted)`; prefer a booted device (any
/// family — the user chose it), else the first iPhone.
pub fn parseSimulatorDeviceList(listing: []const u8) ?[]const u8 {
    var first_iphone: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "--") or std.mem.startsWith(u8, trimmed, "==")) continue;
        const paren = std.mem.indexOf(u8, trimmed, " (") orelse continue;
        const name = trimmed[0..paren];
        if (std.mem.indexOf(u8, trimmed, "(Booted)") != null) return name;
        if (first_iphone == null and std.mem.startsWith(u8, name, "iPhone")) first_iphone = name;
    }
    return first_iphone;
}

pub fn hasOptimizeFlag(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-Doptimize")) return true;
        if (std.mem.startsWith(u8, arg, "--release")) return true;
    }
    return false;
}

/// Spawn with inherited stdio and turn a non-zero exit into `fail_error`
/// after naming the failed step (never fail in silence).
fn runInherit(io: std.Io, argv: []const []const u8, fail_error: anyerror) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("native (ios): `{s}` step failed\n", .{argv[0]});
    return fail_error;
}

/// Run capturing (and discarding) output — for idempotent commands whose
/// failure chatter would only mislead (`simctl boot` on a booted device).
fn runQuiet(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.SimulatorCommandFailed;
}

fn xmlEscapeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, ch),
        }
    }
    return out.toOwnedSlice(allocator);
}

test "bundle ids normalize underscores for the Apple identifier grammar" {
    const mapped = try bundleIdAlloc(std.testing.allocator, "dev.native_sdk.ui_inbox");
    defer std.testing.allocator.free(mapped);
    try std.testing.expectEqualStrings("dev.native-sdk.ui-inbox", mapped);
}

test "host info plist carries app identity and full-screen launch keys" {
    const text = try infoPlistAlloc(std.testing.allocator, .{
        .id = "dev.native_sdk.calculator",
        .name = "calculator",
        .display_name = "Calculator <Pro>",
        .version = "0.2.0",
    });
    defer std.testing.allocator.free(text);
    // The bundle id is normalized for iOS (underscore -> hyphen).
    try std.testing.expect(std.mem.indexOf(u8, text, "<string>dev.native-sdk.calculator</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<string>calculator</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<string>Calculator &lt;Pro&gt;</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<string>0.2.0</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "UILaunchScreen") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "UISupportedInterfaceOrientations") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "CFBundleExecutable") != null);
    // The ATS exception is scoped to local networking only (the dev loop
    // streams media from the Mac); arbitrary loads stay forbidden.
    try std.testing.expect(std.mem.indexOf(u8, text, "NSAllowsLocalNetworking") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "NSAllowsArbitraryLoads") == null);
}

test "the embedded host sources are the toolkit host" {
    try std.testing.expect(std.mem.indexOf(u8, host_source, "NativeSdkCanvasViewController") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "native_sdk_app_viewport") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "native_sdk_app_set_text_measure") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "_dyld_get_image_header_containing_address") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_header, "native_sdk_app_render_pixels") != null);
    // The audio service: registered before start, session category
    // playback, and the interruption handler that pauses the transport
    // and reports the paused state through one immediate position event.
    try std.testing.expect(std.mem.indexOf(u8, host_source, "native_sdk_app_set_audio_service") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "AVAudioSessionCategoryPlayback") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "AVAudioSessionInterruptionNotification") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "handleSessionInterruption") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_header, "native_sdk_audio_service_t") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_header, "native_sdk_app_audio_event") != null);
    // Platform push/pop navigation: the depth projection poll, the REAL
    // interactive pop recognizer, and the completed gesture's exactly-once
    // back-command dispatch.
    try std.testing.expect(std.mem.indexOf(u8, host_source, "native_sdk_app_chrome_navigation_depth") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "interactivePopGestureRecognizer") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "completeInteractivePop") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_header, "native_sdk_app_chrome_navigation_back_command") != null);
}

test "simulator device parsing prefers booted devices then iPhones" {
    const listing =
        \\== Devices ==
        \\-- iOS 18.0 --
        \\    iPad mini (6th generation) (AA773561-F796-439A-90F4-A92ABFB0251C) (Shutdown)
        \\    iPhone 16 Pro (B8BF491D-D3F4-473F-9453-4C1C8017E912) (Shutdown)
        \\    iPhone 16 (A194A9F7-5979-4B39-A5CF-8EB010CF7160) (Booted)
        \\
    ;
    try std.testing.expectEqualStrings("iPhone 16", parseSimulatorDeviceList(listing).?);

    const shutdown_only =
        \\-- iOS 18.0 --
        \\    iPad mini (6th generation) (AA773561-F796-439A-90F4-A92ABFB0251C) (Shutdown)
        \\    iPhone 16 Pro (B8BF491D-D3F4-473F-9453-4C1C8017E912) (Shutdown)
        \\
    ;
    try std.testing.expectEqualStrings("iPhone 16 Pro", parseSimulatorDeviceList(shutdown_only).?);
    try std.testing.expectEqual(@as(?[]const u8, null), parseSimulatorDeviceList("== Devices ==\n"));
}
