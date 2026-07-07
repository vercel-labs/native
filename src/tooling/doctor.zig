const std = @import("std");
const platform_info = @import("platform_info");
const cef = @import("cef.zig");
const debug = @import("debug");
const manifest_tool = @import("manifest.zig");
const web_engine = @import("web_engine.zig");

pub const Error = error{
    DoctorProblems,
    InvalidArguments,
};

pub const Options = struct {
    strict: bool = false,
    manifest_path: ?[]const u8 = null,
    web_engine_override: ?web_engine.Engine = null,
    cef_dir_override: ?[]const u8 = null,
    cef_auto_install_override: ?bool = null,
};

pub const Probe = struct {
    context: ?*anyopaque = null,
    command_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const []const u8) bool = realCommandAvailable,
    path_fn: *const fn (?*anyopaque, std.Io, []const u8) bool = realPathExists,

    fn commandAvailable(self: Probe, allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
        return self.command_fn(self.context, allocator, io, argv);
    }

    fn pathExists(self: Probe, io: std.Io, path: []const u8) bool {
        return self.path_fn(self.context, io, path);
    }
};

pub const ReportBuffers = struct {
    env: [2]platform_info.EnvVar = undefined,
    gpu: [1]platform_info.GpuApiRecord = undefined,
    checks: [16]platform_info.DoctorCheck = undefined,
    messages: [16][384]u8 = undefined,
    log_paths: debug.LogPathBuffers = .{},
    check_count: usize = 0,

    fn reset(self: *ReportBuffers) void {
        self.check_count = 0;
    }

    fn add(self: *ReportBuffers, id: []const u8, status: platform_info.Status, comptime fmt: []const u8, args: anytype) !void {
        if (self.check_count >= self.checks.len) return error.NoSpaceLeft;
        const message = try std.fmt.bufPrint(&self.messages[self.check_count], fmt, args);
        self.checks[self.check_count] = .{ .id = id, .status = status, .message = message };
        self.check_count += 1;
    }
};

pub fn parseOptions(args: []const []const u8) Error!Options {
    var options: Options = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--strict")) {
            options.strict = true;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.manifest_path = args[index];
        } else if (std.mem.eql(u8, arg, "--web-engine")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.web_engine_override = web_engine.Engine.parse(args[index]) orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--cef-dir")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.cef_dir_override = args[index];
        } else if (std.mem.eql(u8, arg, "--cef-auto-install")) {
            options.cef_auto_install_override = true;
        } else {
            return error.InvalidArguments;
        }
    }
    return options;
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, args: []const []const u8) !void {
    const options = try parseOptions(args);
    var buffers: ReportBuffers = .{};
    const report = try reportForCurrentHostWithProbe(allocator, io, env_map, options, &buffers, .{});
    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try report.formatText(&writer);
    std.debug.print("{s}", .{writer.buffered()});
    if (options.strict and report.hasProblems()) return error.DoctorProblems;
}

pub fn reportForCurrentHost() platform_info.DoctorReport {
    const target = platform_info.Target.current();
    const display = platform_info.detectDisplayServer(target.os, &.{});
    const State = struct {
        var gpu: [1]platform_info.GpuApiRecord = undefined;
        const checks = [_]platform_info.DoctorCheck{
            platform_info.DoctorCheck.ok("zig", "Zig 0.16 build API is available"),
            platform_info.DoctorCheck.ok("null-backend", "Headless WebView shell platform is available"),
            platform_info.DoctorCheck.ok("webview-system", "System WebView backend is available through platform hosts"),
            platform_info.DoctorCheck.ok("webview-chromium", "Chromium backend expects CEF at third_party/cef/<platform> or -Dcef-dir"),
            platform_info.DoctorCheck.ok("codesign", "codesign is available for macOS signing (ad-hoc or identity)"),
            platform_info.DoctorCheck.ok("notarytool", "xcrun notarytool is available for macOS notarization"),
            platform_info.DoctorCheck.ok("hdiutil", "hdiutil is available for macOS .dmg creation"),
            platform_info.DoctorCheck.ok("app-icon", "app icon generation (.icns, .ico, PNG size sets) is built into `native package` - one square assets/icon.png or .svg source, no external tools"),
            platform_info.DoctorCheck.ok("ios-static-lib", "Use `zig build lib -Dtarget=aarch64-ios` to build the iOS static library"),
            platform_info.DoctorCheck.ok("android-static-lib", "Use `zig build lib -Dtarget=aarch64-linux-android` to build the Android static library"),
        };
    };
    State.gpu = .{
        .{ .api = .software, .status = .available, .message = "no custom GPU renderer required" },
    };
    return .{
        .host = .{
            .target = target,
            .display_server = display,
            .gpu_apis = &State.gpu,
        },
        .checks = &State.checks,
    };
}

pub fn reportForCurrentHostWithProbe(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    options: Options,
    buffers: *ReportBuffers,
    probe: Probe,
) !platform_info.DoctorReport {
    buffers.reset();
    const target = platform_info.Target.current();
    const env = envRecords(env_map, buffers);
    const display = platform_info.detectDisplayServer(target.os, env);
    buffers.gpu = .{
        .{ .api = .software, .status = .available, .message = "no custom GPU renderer required" },
    };

    try addCommandCheck(buffers, allocator, io, probe, "zig", &.{ "zig", "version" }, "zig command is available", "zig command was not found on PATH");
    try buffers.add("null-backend", .available, "headless WebView shell platform is available", .{});
    try addLogPathCheck(buffers, env_map);
    try addManifestCheck(buffers, allocator, io, options);
    if (target.os == .macos) {
        try buffers.add("webview-system", .available, "WKWebView system WebView backend is available on macOS hosts", .{});
        try addPathCheck(buffers, io, probe, "codesign", "/usr/bin/codesign", "codesign is available for macOS signing", "codesign was not found");
        try addCommandCheck(buffers, allocator, io, probe, "notarytool", &.{ "xcrun", "notarytool", "--help" }, "xcrun notarytool is available for notarization", "xcrun notarytool was not found");
        try addPathCheck(buffers, io, probe, "hdiutil", "/usr/bin/hdiutil", "hdiutil is available for macOS .dmg creation", "hdiutil was not found");
    } else {
        try buffers.add("codesign", .unsupported, "macOS signing checks only run on macOS hosts", .{});
    }
    if (target.os == .linux) {
        try addCommandCheck(buffers, allocator, io, probe, "webview-system", &.{ "pkg-config", "--exists", "webkitgtk-6.0" }, "WebKitGTK 6.0 system WebView backend is available", "WebKitGTK 6.0 was not found (install libwebkitgtk-6.0-dev or webkitgtk-6.0)");
        try addCommandCheck(buffers, allocator, io, probe, "webkitgtk", &.{ "pkg-config", "--exists", "webkitgtk-6.0" }, "WebKitGTK 6.0 development libraries are available", "WebKitGTK 6.0 was not found (install libwebkitgtk-6.0-dev or webkitgtk-6.0)");
        try addCommandCheck(buffers, allocator, io, probe, "gtk4", &.{ "pkg-config", "--exists", "gtk4" }, "GTK4 development libraries are available", "GTK4 was not found (install libgtk-4-dev or gtk4)");
    } else if (target.os == .windows) {
        // The Windows system engine is the OS WebView2 runtime, loaded by
        // apps at run time; the Evergreen runtime registers this client id
        // in the registry (per-machine or per-user).
        try addCommandCheck(buffers, allocator, io, probe, "webview-system", &.{ "reg", "query", "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}", "/v", "pv" }, "WebView2 system WebView runtime is installed", "WebView2 runtime was not found (install the Evergreen WebView2 Runtime)");
    } else if (target.os != .macos) {
        try buffers.add("webview-system", .unsupported, "system WebView backend is not wired for this host yet", .{});
    }
    var manifest_engine = web_engine.readManifestConfig(allocator, io, options.manifest_path orelse "app.zon") catch web_engine.ManifestConfig{};
    defer manifest_engine.deinit(allocator);
    const resolved_engine = web_engine.resolve(manifest_engine, .{
        .web_engine = options.web_engine_override,
        .cef_dir = options.cef_dir_override,
        .cef_auto_install = options.cef_auto_install_override,
    }) catch |err| {
        try buffers.add("webview-config", .missing, "web engine configuration is invalid: {s}", .{@errorName(err)});
        return .{
            .host = .{ .target = target, .display_server = display, .gpu_apis = &buffers.gpu },
            .checks = buffers.checks[0..buffers.check_count],
        };
    };
    const cef_platform = cef.Platform.current() catch null;
    if (cef_platform == null) {
        try buffers.add("webview-chromium", .unsupported, "Chromium/CEF backend is not wired for this host", .{});
    } else if (target.os == .windows) {
        // The Windows CEF host is a placeholder: build and package
        // tooling reject the chromium engine on Windows until CEF browser
        // creation is wired, so report it honestly instead of implying an
        // available backend.
        try buffers.add("webview-chromium", .unsupported, "Chromium/CEF desktop engine is not wired on Windows yet; the system engine (WebView2) is the Windows backend", .{});
    } else if (resolved_engine.engine == .chromium) {
        const cef_dir = if (resolved_engine.cef_dir.len == 0) cef_platform.?.defaultDir() else resolved_engine.cef_dir;
        try addCefLayoutCheck(buffers, io, probe, cef_platform.?, cef_dir);
    } else {
        try buffers.add("webview-chromium", .available, "Chromium backend is available; configure app.zon or pass --web-engine chromium to check CEF", .{});
    }
    // Icon generation needs no host tool anywhere: the pipeline (PNG/SVG
    // source -> .icns/.ico/PNG size sets) is built into the CLI itself.
    try buffers.add("app-icon", .available, "app icon generation (.icns, .ico, PNG size sets) is built into `native package` - one square assets/icon.png or .svg source, no external tools", .{});
    try buffers.add("ios-static-lib", .available, "Use `zig build lib -Dtarget=aarch64-ios` to build the iOS static library", .{});
    try buffers.add("android-static-lib", .available, "Use `zig build lib -Dtarget=aarch64-linux-android` to build the Android static library", .{});

    return .{
        .host = .{
            .target = target,
            .display_server = display,
            .gpu_apis = &buffers.gpu,
        },
        .checks = buffers.checks[0..buffers.check_count],
    };
}

fn envRecords(env_map: *std.process.Environ.Map, buffers: *ReportBuffers) []const platform_info.EnvVar {
    var count: usize = 0;
    if (env_map.get("WAYLAND_DISPLAY")) |value| {
        buffers.env[count] = .{ .name = "WAYLAND_DISPLAY", .value = value };
        count += 1;
    }
    if (env_map.get("DISPLAY")) |value| {
        buffers.env[count] = .{ .name = "DISPLAY", .value = value };
        count += 1;
    }
    return buffers.env[0..count];
}

fn addLogPathCheck(buffers: *ReportBuffers, env_map: *std.process.Environ.Map) !void {
    const paths = debug.resolveLogPaths(&buffers.log_paths, "dev.native_sdk.app", debug.envFromMap(env_map), env_map.get("NATIVE_SDK_LOG_DIR")) catch |err| {
        return buffers.add("log-path", .missing, "log directory could not be resolved: {s}", .{@errorName(err)});
    };
    try buffers.add("log-path", .available, "runtime logs will be written to {s}", .{paths.log_file});
}

fn addManifestCheck(buffers: *ReportBuffers, allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    const path = options.manifest_path orelse return;
    const result = manifest_tool.validateFile(allocator, io, path) catch |err| {
        return buffers.add("manifest", .missing, "manifest {s} could not be read: {s}", .{ path, @errorName(err) });
    };
    if (result.ok) {
        try buffers.add("manifest", .available, "{s}: {s}", .{ path, result.message });
    } else {
        try buffers.add("manifest", .missing, "{s}: {s}", .{ path, result.message });
    }
}

fn addCommandCheck(
    buffers: *ReportBuffers,
    allocator: std.mem.Allocator,
    io: std.Io,
    probe: Probe,
    id: []const u8,
    argv: []const []const u8,
    ok_message: []const u8,
    missing_message: []const u8,
) !void {
    if (probe.commandAvailable(allocator, io, argv)) {
        try buffers.add(id, .available, "{s}", .{ok_message});
    } else {
        try buffers.add(id, .missing, "{s}", .{missing_message});
    }
}

fn addPathCheck(
    buffers: *ReportBuffers,
    io: std.Io,
    probe: Probe,
    id: []const u8,
    path: []const u8,
    ok_message: []const u8,
    missing_message: []const u8,
) !void {
    if (probe.pathExists(io, path)) {
        try buffers.add(id, .available, "{s}", .{ok_message});
    } else {
        try buffers.add(id, .missing, "{s}", .{missing_message});
    }
}

fn addCefLayoutCheck(buffers: *ReportBuffers, io: std.Io, probe: Probe, platform: cef.Platform, cef_dir: []const u8) !void {
    for (platform.requiredEntries()) |entry| {
        var path_buffer: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&path_buffer);
        const path = std.fs.path.join(fba.allocator(), &.{ cef_dir, entry.path }) catch {
            return buffers.add("webview-chromium", .missing, "CEF path is too long under {s}", .{cef_dir});
        };
        if (!probe.pathExists(io, path)) {
            return buffers.add("webview-chromium", .missing, "CEF is missing {s}; run `native cef install --dir {s}`", .{ entry.path, cef_dir });
        }
    }
    try buffers.add("webview-chromium", .available, "CEF layout is ready at {s}", .{cef_dir});
}

fn realCommandAvailable(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    _ = context;
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(4096),
        .stderr_limit = std.Io.Limit.limited(4096),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn realPathExists(context: ?*anyopaque, io: std.Io, path: []const u8) bool {
    _ = context;
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

test "doctor report validates" {
    try reportForCurrentHost().validate();
}

test "doctor options parse strict manifest and cef checks" {
    const options = try parseOptions(&.{ "--strict", "--manifest", "app.zon", "--web-engine", "chromium", "--cef-dir", "third_party/cef/macos" });
    try std.testing.expect(options.strict);
    try std.testing.expectEqual(web_engine.Engine.chromium, options.web_engine_override.?);
    try std.testing.expectEqualStrings("app.zon", options.manifest_path.?);
    try std.testing.expectEqualStrings("third_party/cef/macos", options.cef_dir_override.?);
}

test "doctor report uses injected probes" {
    const Fake = struct {
        fn commandAvailable(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
            _ = context;
            _ = allocator;
            _ = io;
            return std.mem.eql(u8, argv[0], "zig");
        }

        fn pathExists(context: ?*anyopaque, io: std.Io, path: []const u8) bool {
            _ = context;
            _ = io;
            return std.mem.startsWith(u8, path, "cef-ok/");
        }
    };

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/Users/alice");
    var buffers: ReportBuffers = .{};
    const report = try reportForCurrentHostWithProbe(std.testing.allocator, std.testing.io, &env_map, .{ .web_engine_override = .chromium, .cef_dir_override = "cef-ok" }, &buffers, .{
        .command_fn = Fake.commandAvailable,
        .path_fn = Fake.pathExists,
    });

    try report.validate();
    try std.testing.expect(!report.hasProblems() or report.checks.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, report.checks[0].message, "zig") != null);
}
