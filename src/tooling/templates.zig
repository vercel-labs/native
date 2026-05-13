const std = @import("std");

const fallback_icon_icns = "icns\x00\x00\x00\x08";

pub const Frontend = enum {
    next,
    vite,
    react,
    svelte,
    vue,
    angular,

    pub fn parse(value: []const u8) ?Frontend {
        if (std.mem.eql(u8, value, "next")) return .next;
        if (std.mem.eql(u8, value, "vite")) return .vite;
        if (std.mem.eql(u8, value, "react")) return .react;
        if (std.mem.eql(u8, value, "svelte")) return .svelte;
        if (std.mem.eql(u8, value, "vue")) return .vue;
        if (std.mem.eql(u8, value, "angular")) return .angular;
        return null;
    }

    pub fn distDir(self: Frontend) []const u8 {
        return switch (self) {
            .next => "frontend/out",
            .vite, .react, .svelte, .vue, .angular => "frontend/dist",
        };
    }

    pub fn devPort(self: Frontend) []const u8 {
        return switch (self) {
            .next => "3000",
            .vite, .react, .svelte, .vue => "5173",
            .angular => "4200",
        };
    }

    pub fn devUrl(self: Frontend) []const u8 {
        return switch (self) {
            .next => "http://127.0.0.1:3000/",
            .vite, .react, .svelte, .vue => "http://127.0.0.1:5173/",
            .angular => "http://127.0.0.1:4200/",
        };
    }
};

pub const InitOptions = struct {
    app_name: []const u8,
    framework_path: []const u8 = ".",
    frontend: Frontend = .vite,
};

pub fn writeDefaultApp(allocator: std.mem.Allocator, io: std.Io, destination: []const u8, options: InitOptions) !void {
    const names = try TemplateNames.init(allocator, options.app_name);
    defer names.deinit(allocator);
    const framework_path = try defaultFrameworkPath(allocator, io, destination, options.framework_path);
    defer allocator.free(framework_path);

    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, destination);
    var app_dir = try cwd.openDir(io, destination, .{});
    defer app_dir.close(io);

    try app_dir.createDirPath(io, "src");
    try app_dir.createDirPath(io, "assets");

    const build_zig = try buildZig(allocator, names, framework_path, options.frontend);
    defer allocator.free(build_zig);
    const build_zon = try buildZon(allocator, names);
    defer allocator.free(build_zon);
    const main_zig = try mainZig(allocator, names, options.frontend);
    defer allocator.free(main_zig);
    const app_zon = try appZon(allocator, names, options.frontend);
    defer allocator.free(app_zon);
    const readme_md = try readme(allocator, names, framework_path, options.frontend);
    defer allocator.free(readme_md);

    try writeFile(app_dir, io, "build.zig", build_zig);
    try writeFile(app_dir, io, "build.zig.zon", build_zon);
    try writeFile(app_dir, io, "src/main.zig", main_zig);
    try writeFile(app_dir, io, "src/runner.zig", runnerZig());
    try writeFile(app_dir, io, "app.zon", app_zon);
    const icon_bytes = readFile(allocator, io, "assets/icon.icns") catch fallback_icon_icns;
    defer if (icon_bytes.ptr != fallback_icon_icns.ptr) allocator.free(icon_bytes);
    try writeFile(app_dir, io, "assets/icon.icns", icon_bytes);
    try writeFile(app_dir, io, "README.md", readme_md);

    try writeFrontendFiles(allocator, io, app_dir, names, options.frontend);
}

fn writeFile(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024));
}

const TemplateNames = struct {
    package_name: []const u8,
    module_name: []const u8,
    display_name: []const u8,
    app_id: []const u8,

    fn init(allocator: std.mem.Allocator, app_name: []const u8) !TemplateNames {
        const package_name = try normalizePackageName(allocator, app_name);
        errdefer allocator.free(package_name);
        const module_name = try normalizeModuleName(allocator, package_name);
        errdefer allocator.free(module_name);
        const display_name = try displayName(allocator, package_name);
        errdefer allocator.free(display_name);
        const app_id = try std.fmt.allocPrint(allocator, "dev.zero_native.{s}", .{package_name});
        errdefer allocator.free(app_id);
        return .{
            .package_name = package_name,
            .module_name = module_name,
            .display_name = display_name,
            .app_id = app_id,
        };
    }

    fn deinit(self: TemplateNames, allocator: std.mem.Allocator) void {
        allocator.free(self.package_name);
        allocator.free(self.module_name);
        allocator.free(self.display_name);
        allocator.free(self.app_id);
    }
};

fn buildZig(allocator: std.mem.Allocator, names: TemplateNames, framework_path: []const u8, frontend: Frontend) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\
        \\const PlatformOption = enum {
        \\    auto,
        \\    @"null",
        \\    macos,
        \\    linux,
        \\    windows,
        \\};
        \\
        \\const TraceOption = enum {
        \\    off,
        \\    events,
        \\    runtime,
        \\    all,
        \\};
        \\
        \\const WebEngineOption = enum {
        \\    system,
        \\    chromium,
        \\};
        \\
        \\const PackageTarget = enum {
        \\    macos,
        \\    windows,
        \\    linux,
        \\};
        \\
        \\const default_zero_native_path =
    );
    try appendZigString(&out, allocator, framework_path);
    try out.appendSlice(allocator, ";\nconst app_exe_name = ");
    try appendZigString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\;
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = zeroNativeTarget(b);
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const platform_option = b.option(PlatformOption, "platform", "Desktop backend: auto, null, macos, linux, windows") orelse .auto;
        \\    const trace_option = b.option(TraceOption, "trace", "Trace output: off, events, runtime, all") orelse .events;
        \\    const debug_overlay = b.option(bool, "debug-overlay", "Enable debug overlay output") orelse false;
        \\    const automation_enabled = b.option(bool, "automation", "Enable zero-native automation artifacts") orelse false;
        \\    const js_bridge_enabled = b.option(bool, "js-bridge", "Enable optional JavaScript bridge stubs") orelse false;
        \\    const web_engine_override = b.option(WebEngineOption, "web-engine", "Override app.zon web engine: system, chromium");
        \\    const cef_dir_override = b.option([]const u8, "cef-dir", "Override CEF root directory for Chromium builds");
        \\    const cef_auto_install_override = b.option(bool, "cef-auto-install", "Override app.zon CEF auto-install setting");
        \\    const package_target = b.option(PackageTarget, "package-target", "Package target: macos, windows, linux") orelse .macos;
        \\    const zero_native_path = b.option([]const u8, "zero-native-path", "Path to the zero-native framework checkout") orelse default_zero_native_path;
        \\    const optimize_name = @tagName(optimize);
        \\    const selected_platform: PlatformOption = switch (platform_option) {
        \\        .auto => if (target.result.os.tag == .macos) .macos else if (target.result.os.tag == .linux) .linux else if (target.result.os.tag == .windows) .windows else .@"null",
        \\        else => platform_option,
        \\    };
        \\    if (selected_platform == .macos and target.result.os.tag != .macos) {
        \\        @panic("-Dplatform=macos requires a macOS target");
        \\    }
        \\    if (selected_platform == .linux and target.result.os.tag != .linux) {
        \\        @panic("-Dplatform=linux requires a Linux target");
        \\    }
        \\    if (selected_platform == .windows and target.result.os.tag != .windows) {
        \\        @panic("-Dplatform=windows requires a Windows target");
        \\    }
        \\    const app_web_engine = appWebEngineConfig();
        \\    const web_engine = web_engine_override orelse app_web_engine.web_engine;
        \\    const cef_dir = cef_dir_override orelse defaultCefDir(selected_platform, app_web_engine.cef_dir);
        \\    const cef_auto_install = cef_auto_install_override orelse app_web_engine.cef_auto_install;
        \\    if (web_engine == .chromium and selected_platform == .@"null") {
        \\        @panic("-Dweb-engine=chromium requires -Dplatform=macos, linux, or windows");
        \\    }
        \\
        \\    const zero_native_mod = zeroNativeModule(b, target, optimize, zero_native_path);
        \\    const options = b.addOptions();
        \\    options.addOption([]const u8, "platform", switch (selected_platform) {
        \\        .auto => unreachable,
        \\        .@"null" => "null",
        \\        .macos => "macos",
        \\        .linux => "linux",
        \\        .windows => "windows",
        \\    });
        \\    options.addOption([]const u8, "trace", @tagName(trace_option));
        \\    options.addOption([]const u8, "web_engine", @tagName(web_engine));
        \\    options.addOption(bool, "debug_overlay", debug_overlay);
        \\    options.addOption(bool, "automation", automation_enabled);
        \\    options.addOption(bool, "js_bridge", js_bridge_enabled);
        \\    const options_mod = options.createModule();
        \\
        \\    const runner_mod = localModule(b, target, optimize, "src/runner.zig");
        \\    runner_mod.addImport("zero-native", zero_native_mod);
        \\    runner_mod.addImport("build_options", options_mod);
        \\
        \\    const app_mod = localModule(b, target, optimize, "src/main.zig");
        \\    app_mod.addImport("zero-native", zero_native_mod);
        \\    app_mod.addImport("runner", runner_mod);
        \\    const exe = b.addExecutable(.{
        \\        .name = app_exe_name,
        \\        .root_module = app_mod,
        \\    });
        \\    linkPlatform(b, target, app_mod, exe, selected_platform, web_engine, zero_native_path, cef_dir, cef_auto_install);
        \\    b.installArtifact(exe);
        \\
        \\    const frontend_install = b.addSystemCommand(&.{ "npm", "install", "--prefix", "frontend" });
        \\    const frontend_install_step = b.step("frontend-install", "Install frontend dependencies");
        \\    frontend_install_step.dependOn(&frontend_install.step);
        \\
        \\    const frontend_build = b.addSystemCommand(&.{ "npm", "--prefix", "frontend", "run", "build" });
        \\    frontend_build.step.dependOn(&frontend_install.step);
        \\    const frontend_step = b.step("frontend-build", "Build the frontend");
        \\    frontend_step.dependOn(&frontend_build.step);
        \\
        \\    const run = b.addRunArtifact(exe);
        \\    run.step.dependOn(&frontend_build.step);
        \\    addCefRuntimeRunFiles(b, target, run, exe, web_engine, cef_dir);
        \\    const run_step = b.step("run", "Run the app");
        \\    run_step.dependOn(&run.step);
        \\
        \\    const dev = b.addSystemCommand(&.{ "zero-native", "dev", "--manifest", "app.zon", "--binary" });
        \\    dev.addFileArg(exe.getEmittedBin());
        \\    dev.step.dependOn(&exe.step);
        \\    dev.step.dependOn(&frontend_install.step);
        \\    const dev_step = b.step("dev", "Run the frontend dev server and native shell");
        \\    dev_step.dependOn(&dev.step);
        \\
        \\    const package = b.addSystemCommand(&.{
        \\        "zero-native",
        \\        "package",
        \\        "--target",
        \\        @tagName(package_target),
        \\        "--manifest",
        \\        "app.zon",
        \\        "--assets",
    );
    try appendZigString(&out, allocator, frontend.distDir());
    try out.appendSlice(allocator,
        \\,
        \\        "--optimize",
        \\        optimize_name,
        \\        "--output",
        \\        b.fmt("zig-out/package/{s}-0.1.0-{s}-{s}{s}", .{ app_exe_name, @tagName(package_target), optimize_name, packageSuffix(package_target) }),
        \\        "--binary",
        \\    });
        \\    package.addFileArg(exe.getEmittedBin());
        \\    package.addArgs(&.{ "--web-engine", @tagName(web_engine), "--cef-dir", cef_dir });
        \\    if (cef_auto_install) package.addArg("--cef-auto-install");
        \\    package.step.dependOn(&exe.step);
        \\    package.step.dependOn(&frontend_build.step);
        \\    const package_step = b.step("package", "Create a local package artifact");
        \\    package_step.dependOn(&package.step);
        \\
        \\    const tests = b.addTest(.{ .root_module = app_mod });
        \\    const test_step = b.step("test", "Run tests");
        \\    test_step.dependOn(&b.addRunArtifact(tests).step);
        \\}
        \\
        \\fn zeroNativeTarget(b: *std.Build) std.Build.ResolvedTarget {
        \\    const target = b.standardTargetOptions(.{});
        \\    if (target.result.os.tag != .macos) return target;
        \\
        \\    if (b.sysroot == null) {
        \\        b.sysroot = macosSdkPath(b) orelse b.sysroot;
        \\    }
        \\
        \\    var query = target.query;
        \\    query.os_tag = .macos;
        \\    query.os_version_min = .{ .semver = .{ .major = 11, .minor = 0, .patch = 0 } };
        \\    return b.resolveTargetQuery(query);
        \\}
        \\
        \\fn macosSdkPath(b: *std.Build) ?[]const u8 {
        \\    if (b.graph.environ_map.get("SDKROOT")) |sdkroot| {
        \\        if (sdkroot.len > 0) return sdkroot;
        \\    }
        \\
        \\    const result = std.process.run(b.allocator, b.graph.io, .{
        \\        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
        \\        .stdout_limit = .limited(4096),
        \\        .stderr_limit = .limited(4096),
        \\    }) catch return null;
        \\    defer b.allocator.free(result.stderr);
        \\    if (result.term != .exited or result.term.exited != 0) {
        \\        b.allocator.free(result.stdout);
        \\        return null;
        \\    }
        \\    return std.mem.trimEnd(u8, result.stdout, "\r\n");
        \\}
        \\
        \\fn localModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Module {
        \\    return b.createModule(.{
        \\        .root_source_file = b.path(path),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\}
        \\
        \\fn zeroNativePath(b: *std.Build, zero_native_path: []const u8, sub_path: []const u8) std.Build.LazyPath {
        \\    return .{ .cwd_relative = b.pathJoin(&.{ zero_native_path, sub_path }) };
        \\}
        \\
        \\fn zeroNativeModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, zero_native_path: []const u8) *std.Build.Module {
        \\    const geometry_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/geometry/root.zig");
        \\    const assets_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/assets/root.zig");
        \\    const app_dirs_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/app_dirs/root.zig");
        \\    const trace_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/trace/root.zig");
        \\    const app_manifest_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/app_manifest/root.zig");
        \\    const diagnostics_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/diagnostics/root.zig");
        \\    const platform_info_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/platform_info/root.zig");
        \\    const json_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/json/root.zig");
        \\    const debug_mod = externalModule(b, target, optimize, zero_native_path, "src/debug/root.zig");
        \\    debug_mod.addImport("app_dirs", app_dirs_mod);
        \\    debug_mod.addImport("trace", trace_mod);
        \\
        \\    const zero_native_mod = externalModule(b, target, optimize, zero_native_path, "src/root.zig");
        \\    zero_native_mod.addImport("geometry", geometry_mod);
        \\    zero_native_mod.addImport("assets", assets_mod);
        \\    zero_native_mod.addImport("app_dirs", app_dirs_mod);
        \\    zero_native_mod.addImport("trace", trace_mod);
        \\    zero_native_mod.addImport("app_manifest", app_manifest_mod);
        \\    zero_native_mod.addImport("diagnostics", diagnostics_mod);
        \\    zero_native_mod.addImport("platform_info", platform_info_mod);
        \\    zero_native_mod.addImport("json", json_mod);
        \\    return zero_native_mod;
        \\}
        \\
        \\fn externalModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, zero_native_path: []const u8, path: []const u8) *std.Build.Module {
        \\    return b.createModule(.{
        \\        .root_source_file = zeroNativePath(b, zero_native_path, path),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\}
        \\
        \\fn linkPlatform(b: *std.Build, target: std.Build.ResolvedTarget, app_mod: *std.Build.Module, exe: *std.Build.Step.Compile, platform: PlatformOption, web_engine: WebEngineOption, zero_native_path: []const u8, cef_dir: []const u8, cef_auto_install: bool) void {
        \\    if (platform == .macos) {
        \\        switch (web_engine) {
        \\            .system => {
        \\                const sdk_include = if (b.sysroot) |sysroot| b.fmt("-I{s}/usr/include", .{sysroot}) else "";
        \\                const flags: []const []const u8 = if (b.sysroot) |sysroot| &.{ "-fobjc-arc", "-ObjC", "-mmacosx-version-min=11.0", "-isysroot", sysroot, sdk_include } else &.{ "-fobjc-arc", "-ObjC", "-mmacosx-version-min=11.0" };
        \\                app_mod.addCSourceFile(.{ .file = zeroNativePath(b, zero_native_path, "src/platform/macos/appkit_host.m"), .flags = flags });
        \\                app_mod.linkFramework("WebKit", .{});
        \\            },
        \\            .chromium => {
        \\                const cef_check = addCefCheck(b, target, cef_dir);
        \\                if (cef_auto_install) {
        \\                    const cef_auto = b.addSystemCommand(&.{ "zero-native", "cef", "install", "--dir", cef_dir });
        \\                    cef_check.step.dependOn(&cef_auto.step);
        \\                }
        \\                exe.step.dependOn(&cef_check.step);
        \\                const include_arg = b.fmt("-I{s}", .{cef_dir});
        \\                const define_arg = b.fmt("-DZERO_NATIVE_CEF_DIR=\"{s}\"", .{cef_dir});
        \\                const sdk_include = if (b.sysroot) |sysroot| b.fmt("-I{s}/usr/include", .{sysroot}) else "";
        \\                const flags: []const []const u8 = if (b.sysroot) |sysroot| &.{ "-fobjc-arc", "-ObjC++", "-std=c++17", "-stdlib=libc++", "-mmacosx-version-min=11.0", "-isysroot", sysroot, sdk_include, include_arg, define_arg } else &.{ "-fobjc-arc", "-ObjC++", "-std=c++17", "-stdlib=libc++", "-mmacosx-version-min=11.0", include_arg, define_arg };
        \\                app_mod.addCSourceFile(.{ .file = zeroNativePath(b, zero_native_path, "src/platform/macos/cef_host.mm"), .flags = flags });
        \\                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.a", .{cef_dir})));
        \\                app_mod.addFrameworkPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
        \\                app_mod.linkFramework("Chromium Embedded Framework", .{});
        \\                app_mod.addRPath(.{ .cwd_relative = "@executable_path/Frameworks" });
        \\            },
        \\        }
        \\        if (b.sysroot) |sysroot| {
        \\            app_mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
        \\        }
        \\        app_mod.linkFramework("AppKit", .{});
        \\        app_mod.linkFramework("Foundation", .{});
        \\        app_mod.linkFramework("UniformTypeIdentifiers", .{});
        \\        app_mod.linkSystemLibrary("c", .{});
        \\        if (web_engine == .chromium) app_mod.linkSystemLibrary("c++", .{});
        \\    } else if (platform == .linux) {
        \\        switch (web_engine) {
        \\            .system => {
        \\                app_mod.addCSourceFile(.{ .file = zeroNativePath(b, zero_native_path, "src/platform/linux/gtk_host.c"), .flags = &.{} });
        \\                app_mod.linkSystemLibrary("gtk4", .{});
        \\                app_mod.linkSystemLibrary("webkitgtk-6.0", .{});
        \\            },
        \\            .chromium => {
        \\                const cef_check = addCefCheck(b, target, cef_dir);
        \\                if (cef_auto_install) {
        \\                    const cef_auto = b.addSystemCommand(&.{ "zero-native", "cef", "install", "--dir", cef_dir });
        \\                    cef_check.step.dependOn(&cef_auto.step);
        \\                }
        \\                exe.step.dependOn(&cef_check.step);
        \\                const include_arg = b.fmt("-I{s}", .{cef_dir});
        \\                const define_arg = b.fmt("-DZERO_NATIVE_CEF_DIR=\"{s}\"", .{cef_dir});
        \\                app_mod.addCSourceFile(.{ .file = zeroNativePath(b, zero_native_path, "src/platform/linux/cef_host.cpp"), .flags = &.{ "-std=c++17", include_arg, define_arg } });
        \\                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.a", .{cef_dir})));
        \\                app_mod.addLibraryPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
        \\                app_mod.linkSystemLibrary("cef", .{});
        \\                app_mod.addRPath(.{ .cwd_relative = "$ORIGIN" });
        \\            },
        \\        }
        \\        app_mod.linkSystemLibrary("c", .{});
        \\        if (web_engine == .chromium) app_mod.linkSystemLibrary("stdc++", .{});
        \\    } else if (platform == .windows) {
        \\        switch (web_engine) {
        \\            .system => app_mod.addCSourceFile(.{ .file = zeroNativePath(b, zero_native_path, "src/platform/windows/webview2_host.cpp"), .flags = &.{ "-std=c++17" } }),
        \\            .chromium => {
        \\                const cef_check = addCefCheck(b, target, cef_dir);
        \\                if (cef_auto_install) {
        \\                    const cef_auto = b.addSystemCommand(&.{ "zero-native", "cef", "install", "--dir", cef_dir });
        \\                    cef_check.step.dependOn(&cef_auto.step);
        \\                }
        \\                exe.step.dependOn(&cef_check.step);
        \\                const include_arg = b.fmt("-I{s}", .{cef_dir});
        \\                const define_arg = b.fmt("-DZERO_NATIVE_CEF_DIR=\"{s}\"", .{cef_dir});
        \\                app_mod.addCSourceFile(.{ .file = zeroNativePath(b, zero_native_path, "src/platform/windows/cef_host.cpp"), .flags = &.{ "-std=c++17", include_arg, define_arg } });
        \\                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.lib", .{cef_dir})));
        \\                app_mod.addLibraryPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
        \\            },
        \\        }
        \\        app_mod.linkSystemLibrary("c", .{});
        \\        app_mod.linkSystemLibrary("c++", .{});
        \\        app_mod.linkSystemLibrary("user32", .{});
        \\        app_mod.linkSystemLibrary("ole32", .{});
        \\        app_mod.linkSystemLibrary("shell32", .{});
        \\        if (web_engine == .chromium) app_mod.linkSystemLibrary("libcef", .{});
        \\    }
        \\}
        \\
        \\fn addCefRuntimeRunFiles(b: *std.Build, target: std.Build.ResolvedTarget, run: *std.Build.Step.Run, exe: *std.Build.Step.Compile, web_engine: WebEngineOption, cef_dir: []const u8) void {
        \\    if (web_engine != .chromium) return;
        \\    if (target.result.os.tag != .macos) return;
        \\    const copy = b.addSystemCommand(&.{ "sh", "-c", b.fmt(
        \\        \\set -e
        \\        \\exe="$0"
        \\        \\exe_dir="$(dirname "$exe")"
        \\        \\rm -rf "zig-out/Frameworks/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/Chromium Embedded Framework.framework" &&
        \\        \\mkdir -p "zig-out/Frameworks" "zig-out/bin/Frameworks" ".zig-cache/o/Frameworks" "$exe_dir" &&
        \\        \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/Frameworks/" &&
        \\        \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/" &&
        \\        \\cp -R "{s}/Release/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/" &&
        \\        \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libEGL.dylib" "$exe_dir/" &&
        \\        \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libGLESv2.dylib" "$exe_dir/" &&
        \\        \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libvk_swiftshader.dylib" "$exe_dir/" &&
        \\        \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/vk_swiftshader_icd.json" "$exe_dir/"
        \\    , .{ cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir }) });
        \\    copy.addFileArg(exe.getEmittedBin());
        \\    run.step.dependOn(&copy.step);
        \\}
        \\
        \\fn addCefCheck(b: *std.Build, target: std.Build.ResolvedTarget, cef_dir: []const u8) *std.Build.Step.Run {
        \\    const script = switch (target.result.os.tag) {
        \\        .macos => b.fmt(
        \\        \\test -f "{s}/include/cef_app.h" &&
        \\        \\test -d "{s}/Release/Chromium Embedded Framework.framework" &&
        \\        \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.a" || {{
        \\        \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
        \\        \\  echo "Expected:" >&2
        \\        \\  echo "  {s}/include/cef_app.h" >&2
        \\        \\  echo "  {s}/Release/Chromium Embedded Framework.framework" >&2
        \\        \\  echo "  {s}/libcef_dll_wrapper/libcef_dll_wrapper.a" >&2
        \\        \\  echo "Fix with: zero-native cef install --dir {s}" >&2
        \\        \\  echo "Or rerun with: -Dcef-auto-install=true" >&2
        \\        \\  echo "Pass -Dcef-dir=/path/to/cef if your bundle lives elsewhere." >&2
        \\        \\  exit 1
        \\        \\}}
        \\        , .{ cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir }),
        \\        .linux => b.fmt(
        \\        \\test -f "{s}/include/cef_app.h" &&
        \\        \\test -f "{s}/Release/libcef.so" &&
        \\        \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.a" || {{
        \\        \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
        \\        \\  echo "Fix with: zero-native cef install --dir {s}" >&2
        \\        \\  exit 1
        \\        \\}}
        \\        , .{ cef_dir, cef_dir, cef_dir, cef_dir }),
        \\        .windows => b.fmt(
        \\        \\test -f "{s}/include/cef_app.h" &&
        \\        \\test -f "{s}/Release/libcef.dll" &&
        \\        \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.lib" || {{
        \\        \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
        \\        \\  echo "Fix with: zero-native cef install --dir {s}" >&2
        \\        \\  exit 1
        \\        \\}}
        \\        , .{ cef_dir, cef_dir, cef_dir, cef_dir }),
        \\        else => "echo unsupported CEF target >&2; exit 1",
        \\    };
        \\    return b.addSystemCommand(&.{ "sh", "-c", script });
        \\}
        \\
        \\fn packageSuffix(target: PackageTarget) []const u8 {
        \\    return switch (target) {
        \\        .macos => ".app",
        \\        .windows, .linux => "",
        \\    };
        \\}
        \\
        \\const AppWebEngineConfig = struct {
        \\    web_engine: WebEngineOption = .system,
        \\    cef_dir: []const u8 = "third_party/cef/macos",
        \\    cef_auto_install: bool = false,
        \\};
        \\
        \\fn defaultCefDir(platform: PlatformOption, configured: []const u8) []const u8 {
        \\    if (!std.mem.eql(u8, configured, "third_party/cef/macos")) return configured;
        \\    return switch (platform) {
        \\        .linux => "third_party/cef/linux",
        \\        .windows => "third_party/cef/windows",
        \\        else => configured,
        \\    };
        \\}
        \\
        \\fn appWebEngineConfig() AppWebEngineConfig {
        \\    const source = @embedFile("app.zon");
        \\    var config: AppWebEngineConfig = .{};
        \\    if (stringField(source, ".web_engine")) |value| {
        \\        config.web_engine = parseWebEngine(value) orelse .system;
        \\    }
        \\    if (objectSection(source, ".cef")) |cef| {
        \\        if (stringField(cef, ".dir")) |value| config.cef_dir = value;
        \\        if (boolField(cef, ".auto_install")) |value| config.cef_auto_install = value;
        \\    }
        \\    return config;
        \\}
        \\
        \\fn parseWebEngine(value: []const u8) ?WebEngineOption {
        \\    if (std.mem.eql(u8, value, "system")) return .system;
        \\    if (std.mem.eql(u8, value, "chromium")) return .chromium;
        \\    return null;
        \\}
        \\
        \\fn stringField(source: []const u8, field: []const u8) ?[]const u8 {
        \\    const field_index = std.mem.indexOf(u8, source, field) orelse return null;
        \\    const equals = std.mem.indexOfScalarPos(u8, source, field_index, '=') orelse return null;
        \\    const start_quote = std.mem.indexOfScalarPos(u8, source, equals, '"') orelse return null;
        \\    const end_quote = std.mem.indexOfScalarPos(u8, source, start_quote + 1, '"') orelse return null;
        \\    return source[start_quote + 1 .. end_quote];
        \\}
        \\
        \\fn objectSection(source: []const u8, field: []const u8) ?[]const u8 {
        \\    const field_index = std.mem.indexOf(u8, source, field) orelse return null;
        \\    const open = std.mem.indexOfScalarPos(u8, source, field_index, '{') orelse return null;
        \\    var depth: usize = 0;
        \\    var index = open;
        \\    while (index < source.len) : (index += 1) {
        \\        switch (source[index]) {
        \\            '{' => depth += 1,
        \\            '}' => {
        \\                depth -= 1;
        \\                if (depth == 0) return source[open + 1 .. index];
        \\            },
        \\            else => {},
        \\        }
        \\    }
        \\    return null;
        \\}
        \\
        \\fn boolField(source: []const u8, field: []const u8) ?bool {
        \\    const field_index = std.mem.indexOf(u8, source, field) orelse return null;
        \\    const equals = std.mem.indexOfScalarPos(u8, source, field_index, '=') orelse return null;
        \\    var index = equals + 1;
        \\    while (index < source.len and std.ascii.isWhitespace(source[index])) : (index += 1) {}
        \\    if (std.mem.startsWith(u8, source[index..], "true")) return true;
        \\    if (std.mem.startsWith(u8, source[index..], "false")) return false;
        \\    return null;
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn buildZon(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\.{
        \\    .name = .
    );
    try out.appendSlice(allocator, names.module_name);
    try out.appendSlice(allocator,
        \\,
        \\    .fingerprint = 0x
    );
    var fingerprint_buffer: [16]u8 = undefined;
    const fingerprint = try std.fmt.bufPrint(&fingerprint_buffer, "{x}", .{fingerprintForName(names.module_name)});
    try out.appendSlice(allocator, fingerprint);
    try out.appendSlice(allocator,
        \\,
        \\    .version = "0.1.0",
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{},
        \\    .paths = .{ "build.zig", "build.zig.zon", "src", "assets", "frontend", "app.zon", "README.md" },
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn mainZig(allocator: std.mem.Allocator, names: TemplateNames, frontend: Frontend) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\const runner = @import("runner");
        \\const zero_native = @import("zero-native");
        \\
        \\pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);
        \\
        \\const App = struct {
        \\    env_map: *std.process.Environ.Map,
        \\
        \\    fn app(self: *@This()) zero_native.App {
        \\        return .{
        \\            .context = self,
        \\            .name =
    );
    try appendZigString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\            .source = zero_native.frontend.productionSource(.{ .dist =
    );
    try appendZigString(&out, allocator, frontend.distDir());
    try out.appendSlice(allocator,
        \\ }),
        \\            .source_fn = source,
        \\        };
        \\    }
        \\
        \\    fn source(context: *anyopaque) anyerror!zero_native.WebViewSource {
        \\        const self: *@This() = @ptrCast(@alignCast(context));
        \\        return zero_native.frontend.sourceFromEnv(self.env_map, .{
        \\            .dist =
    );
    try appendZigString(&out, allocator, frontend.distDir());
    try out.appendSlice(allocator,
        \\,
        \\            .entry = "index.html",
        \\        });
        \\    }
        \\};
        \\
        \\const dev_origins = [_][]const u8{ "zero://app", "zero://inline",
    );
    const dev_origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{s}", .{frontend.devPort()});
    defer allocator.free(dev_origin);
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, dev_origin);
    try out.appendSlice(allocator,
        \\ };
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    var app = App{ .env_map = init.environ_map };
        \\    try runner.runWithOptions(app.app(), .{
        \\        .app_name =
    );
    try appendZigString(&out, allocator, names.display_name);
    try out.appendSlice(allocator,
        \\,
        \\        .window_title =
    );
    try appendZigString(&out, allocator, names.display_name);
    try out.appendSlice(allocator,
        \\,
        \\        .bundle_id =
    );
    try appendZigString(&out, allocator, names.app_id);
    try out.appendSlice(allocator,
        \\,
        \\        .icon_path = "assets/icon.icns",
        \\        .security = .{
        \\            .navigation = .{ .allowed_origins = &dev_origins },
        \\        },
        \\    }, init);
        \\}
        \\
        \\test "app name is configured" {
        \\    try std.testing.expectEqualStrings(
    );
    try appendZigString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
    );
    try appendZigString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\);
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn runnerZig() []const u8 {
    return
    \\const std = @import("std");
    \\const build_options = @import("build_options");
    \\const zero_native = @import("zero-native");
    \\
    \\pub const StdoutTraceSink = struct {
    \\    pub fn sink(self: *StdoutTraceSink) zero_native.trace.Sink {
    \\        return .{ .context = self, .write_fn = write };
    \\    }
    \\
    \\    fn write(context: *anyopaque, record: zero_native.trace.Record) zero_native.trace.WriteError!void {
    \\        _ = context;
    \\        if (!shouldTrace(record)) return;
    \\        var buffer: [1024]u8 = undefined;
    \\        var writer = std.Io.Writer.fixed(&buffer);
    \\        zero_native.trace.formatText(record, &writer) catch return error.OutOfSpace;
    \\        std.debug.print("{s}\n", .{writer.buffered()});
    \\    }
    \\};
    \\
    \\pub const RunOptions = struct {
    \\    app_name: []const u8,
    \\    window_title: []const u8 = "",
    \\    bundle_id: []const u8,
    \\    icon_path: []const u8 = "assets/icon.icns",
    \\    bridge: ?zero_native.BridgeDispatcher = null,
    \\    builtin_bridge: zero_native.BridgePolicy = .{},
    \\    security: zero_native.SecurityPolicy = .{},
    \\    js_window_api: bool = false,
    \\
    \\    fn appInfo(self: RunOptions) zero_native.AppInfo {
    \\        return .{
    \\            .app_name = self.app_name,
    \\            .window_title = self.window_title,
    \\            .bundle_id = self.bundle_id,
    \\            .icon_path = self.icon_path,
    \\        };
    \\    }
    \\};
    \\
    \\pub fn runWithOptions(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    \\    if (build_options.debug_overlay) {
    \\        std.debug.print("debug-overlay=true backend={s} web-engine={s} trace={s}\n", .{ build_options.platform, build_options.web_engine, build_options.trace });
    \\    }
    \\    if (comptime std.mem.eql(u8, build_options.platform, "macos")) {
    \\        try runMacos(app, options, init);
    \\    } else if (comptime std.mem.eql(u8, build_options.platform, "linux")) {
    \\        try runLinux(app, options, init);
    \\    } else if (comptime std.mem.eql(u8, build_options.platform, "windows")) {
    \\        try runWindows(app, options, init);
    \\    } else {
    \\        try runNull(app, options, init);
    \\    }
    \\}
    \\
    \\fn runNull(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    \\    var buffers: StateBuffers = undefined;
    \\    var app_info = options.appInfo();
    \\    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    \\    var null_platform = zero_native.NullPlatform.initWithOptions(.{}, webEngine(), app_info);
    \\    var trace_sink = StdoutTraceSink{};
    \\    var log_buffers: zero_native.debug.LogPathBuffers = .{};
    \\    const log_setup = zero_native.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    \\    if (log_setup) |setup| zero_native.debug.installPanicCapture(init.io, setup.paths);
    \\    var file_trace_sink: zero_native.debug.FileTraceSink = undefined;
    \\    var fanout_sinks: [2]zero_native.trace.Sink = undefined;
    \\    var fanout_sink: zero_native.debug.FanoutTraceSink = undefined;
    \\    var runtime_trace_sink = trace_sink.sink();
    \\    if (log_setup) |setup| {
    \\        file_trace_sink = zero_native.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
    \\        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
    \\        fanout_sink = .{ .sinks = &fanout_sinks };
    \\        runtime_trace_sink = fanout_sink.sink();
    \\    }
    \\    var runtime = zero_native.Runtime.init(.{
    \\        .platform = null_platform.platform(),
    \\        .trace_sink = runtime_trace_sink,
    \\        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
    \\        .bridge = options.bridge,
    \\        .builtin_bridge = options.builtin_bridge,
    \\        .security = options.security,
    \\        .js_window_api = options.js_window_api,
    \\        .automation = if (build_options.automation) zero_native.automation.Server.init(init.io, ".zig-cache/zero-native-automation", app_info.resolvedWindowTitle()) else null,
    \\        .window_state_store = store,
    \\    });
    \\
    \\    try runtime.run(app);
    \\}
    \\
    \\fn runMacos(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    \\    var buffers: StateBuffers = undefined;
    \\    var app_info = options.appInfo();
    \\    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    \\    var mac_platform = try zero_native.platform.macos.MacPlatform.initWithOptions(zero_native.geometry.SizeF.init(720, 480), webEngine(), app_info);
    \\    defer mac_platform.deinit();
    \\    var trace_sink = StdoutTraceSink{};
    \\    var log_buffers: zero_native.debug.LogPathBuffers = .{};
    \\    const log_setup = zero_native.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    \\    if (log_setup) |setup| zero_native.debug.installPanicCapture(init.io, setup.paths);
    \\    var file_trace_sink: zero_native.debug.FileTraceSink = undefined;
    \\    var fanout_sinks: [2]zero_native.trace.Sink = undefined;
    \\    var fanout_sink: zero_native.debug.FanoutTraceSink = undefined;
    \\    var runtime_trace_sink = trace_sink.sink();
    \\    if (log_setup) |setup| {
    \\        file_trace_sink = zero_native.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
    \\        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
    \\        fanout_sink = .{ .sinks = &fanout_sinks };
    \\        runtime_trace_sink = fanout_sink.sink();
    \\    }
    \\    var runtime = zero_native.Runtime.init(.{
    \\        .platform = mac_platform.platform(),
    \\        .trace_sink = runtime_trace_sink,
    \\        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
    \\        .bridge = options.bridge,
    \\        .builtin_bridge = options.builtin_bridge,
    \\        .security = options.security,
    \\        .js_window_api = options.js_window_api,
    \\        .automation = if (build_options.automation) zero_native.automation.Server.init(init.io, ".zig-cache/zero-native-automation", app_info.resolvedWindowTitle()) else null,
    \\        .window_state_store = store,
    \\    });
    \\
    \\    try runtime.run(app);
    \\}
    \\
    \\fn runLinux(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    \\    var buffers: StateBuffers = undefined;
    \\    var app_info = options.appInfo();
    \\    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    \\    var linux_platform = try zero_native.platform.linux.LinuxPlatform.initWithOptions(zero_native.geometry.SizeF.init(720, 480), webEngine(), app_info);
    \\    defer linux_platform.deinit();
    \\    var trace_sink = StdoutTraceSink{};
    \\    var log_buffers: zero_native.debug.LogPathBuffers = .{};
    \\    const log_setup = zero_native.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    \\    if (log_setup) |setup| zero_native.debug.installPanicCapture(init.io, setup.paths);
    \\    var file_trace_sink: zero_native.debug.FileTraceSink = undefined;
    \\    var fanout_sinks: [2]zero_native.trace.Sink = undefined;
    \\    var fanout_sink: zero_native.debug.FanoutTraceSink = undefined;
    \\    var runtime_trace_sink = trace_sink.sink();
    \\    if (log_setup) |setup| {
    \\        file_trace_sink = zero_native.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
    \\        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
    \\        fanout_sink = .{ .sinks = &fanout_sinks };
    \\        runtime_trace_sink = fanout_sink.sink();
    \\    }
    \\    var runtime = zero_native.Runtime.init(.{
    \\        .platform = linux_platform.platform(),
    \\        .trace_sink = runtime_trace_sink,
    \\        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
    \\        .bridge = options.bridge,
    \\        .builtin_bridge = options.builtin_bridge,
    \\        .security = options.security,
    \\        .js_window_api = options.js_window_api,
    \\        .automation = if (build_options.automation) zero_native.automation.Server.init(init.io, ".zig-cache/zero-native-automation", app_info.resolvedWindowTitle()) else null,
    \\        .window_state_store = store,
    \\    });
    \\
    \\    try runtime.run(app);
    \\}
    \\
    \\fn runWindows(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    \\    var buffers: StateBuffers = undefined;
    \\    var app_info = options.appInfo();
    \\    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    \\    var windows_platform = try zero_native.platform.windows.WindowsPlatform.initWithOptions(zero_native.geometry.SizeF.init(720, 480), webEngine(), app_info);
    \\    defer windows_platform.deinit();
    \\    var trace_sink = StdoutTraceSink{};
    \\    var log_buffers: zero_native.debug.LogPathBuffers = .{};
    \\    const log_setup = zero_native.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    \\    if (log_setup) |setup| zero_native.debug.installPanicCapture(init.io, setup.paths);
    \\    var file_trace_sink: zero_native.debug.FileTraceSink = undefined;
    \\    var fanout_sinks: [2]zero_native.trace.Sink = undefined;
    \\    var fanout_sink: zero_native.debug.FanoutTraceSink = undefined;
    \\    var runtime_trace_sink = trace_sink.sink();
    \\    if (log_setup) |setup| {
    \\        file_trace_sink = zero_native.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
    \\        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
    \\        fanout_sink = .{ .sinks = &fanout_sinks };
    \\        runtime_trace_sink = fanout_sink.sink();
    \\    }
    \\    var runtime = zero_native.Runtime.init(.{
    \\        .platform = windows_platform.platform(),
    \\        .trace_sink = runtime_trace_sink,
    \\        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
    \\        .bridge = options.bridge,
    \\        .builtin_bridge = options.builtin_bridge,
    \\        .security = options.security,
    \\        .js_window_api = options.js_window_api,
    \\        .automation = if (build_options.automation) zero_native.automation.Server.init(init.io, ".zig-cache/zero-native-automation", app_info.resolvedWindowTitle()) else null,
    \\        .window_state_store = store,
    \\    });
    \\
    \\    try runtime.run(app);
    \\}
    \\
    \\fn shouldTrace(record: zero_native.trace.Record) bool {
    \\    if (comptime std.mem.eql(u8, build_options.trace, "off")) return false;
    \\    if (comptime std.mem.eql(u8, build_options.trace, "all")) return true;
    \\    if (comptime std.mem.eql(u8, build_options.trace, "events")) return true;
    \\    return std.mem.indexOf(u8, record.name, build_options.trace) != null;
    \\}
    \\
    \\fn webEngine() zero_native.WebEngine {
    \\    if (comptime std.mem.eql(u8, build_options.web_engine, "chromium")) return .chromium;
    \\    return .system;
    \\}
    \\
    \\const StateBuffers = struct {
    \\    state_dir: [1024]u8 = undefined,
    \\    file_path: [1200]u8 = undefined,
    \\    read: [8192]u8 = undefined,
    \\    restored_windows: [zero_native.platform.max_windows]zero_native.WindowOptions = undefined,
    \\};
    \\
    \\fn prepareStateStore(io: std.Io, env_map: *std.process.Environ.Map, app_info: *zero_native.AppInfo, buffers: *StateBuffers) ?zero_native.window_state.Store {
    \\    const paths = zero_native.window_state.defaultPaths(&buffers.state_dir, &buffers.file_path, app_info.bundle_id, zero_native.debug.envFromMap(env_map)) catch return null;
    \\    const store = zero_native.window_state.Store.init(io, paths.state_dir, paths.file_path);
    \\    if (app_info.main_window.restore_state) {
    \\        if (store.loadWindow(app_info.main_window.label, &buffers.read) catch null) |saved| {
    \\            app_info.main_window.default_frame = saved.frame;
    \\        }
    \\    }
    \\    return store;
    \\}
    \\
    ;
}

fn appZon(allocator: std.mem.Allocator, names: TemplateNames, frontend: Frontend) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\.{
        \\    .id =
    );
    try appendZigString(&out, allocator, names.app_id);
    try out.appendSlice(allocator,
        \\,
        \\    .name =
    );
    try appendZigString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\    .display_name =
    );
    try appendZigString(&out, allocator, names.display_name);
    try out.appendSlice(allocator,
        \\,
        \\    .version = "0.1.0",
        \\    .icons = .{ "assets/icon.icns" },
        \\    .platforms = .{ "macos", "linux" },
        \\    .permissions = .{},
        \\    .capabilities = .{ "webview" },
        \\    .frontend = .{
        \\        .dist =
    );
    try appendZigString(&out, allocator, frontend.distDir());
    try out.appendSlice(allocator,
        \\,
        \\        .entry = "index.html",
        \\        .spa_fallback = true,
        \\        .dev = .{
        \\            .url =
    );
    try appendZigString(&out, allocator, frontend.devUrl());
    try out.appendSlice(allocator,
        \\,
        \\            .command = .{ "npm", "--prefix", "frontend", "run", "dev"
    );
    if (frontend != .next) {
        try out.appendSlice(allocator,
            \\, "--", "--host", "127.0.0.1"
        );
    }
    try out.appendSlice(allocator,
        \\ },
        \\            .ready_path = "/",
        \\            .timeout_ms = 30000,
        \\        },
        \\    },
        \\    .security = .{
        \\        .navigation = .{
        \\            .allowed_origins = .{ "zero://app", "zero://inline",
    );
    try out.appendSlice(allocator, " ");
    const dev_origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{s}", .{frontend.devPort()});
    defer allocator.free(dev_origin);
    try appendZigString(&out, allocator, dev_origin);
    try out.appendSlice(allocator,
        \\ },
        \\            .external_links = .{ .action = "deny" },
        \\        },
        \\    },
        \\    .web_engine = "system",
        \\    .cef = .{ .dir = "third_party/cef/macos", .auto_install = false },
        \\    .windows = .{
        \\        .{ .label = "main", .title =
    );
    try appendZigString(&out, allocator, names.display_name);
    try out.appendSlice(allocator,
        \\, .width = 720, .height = 480, .restore_state = true },
        \\    },
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn writeFrontendFiles(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames, frontend: Frontend) !void {
    switch (frontend) {
        .next => try writeNextFrontend(allocator, io, app_dir, names),
        .vite => try writeViteFrontend(allocator, io, app_dir, names),
        .react => try writeReactFrontend(allocator, io, app_dir, names),
        .svelte => try writeSvelteFrontend(allocator, io, app_dir, names),
        .vue => try writeVueFrontend(allocator, io, app_dir, names),
        .angular => try writeAngularFrontend(allocator, io, app_dir, names),
    }
}

fn angularProjectKey(allocator: std.mem.Allocator, package_name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (package_name.len > 0 and !isAsciiAlpha(package_name[0])) {
        try out.appendSlice(allocator, "app_");
    }
    for (package_name) |ch| {
        const normalized = if (isAsciiAlpha(ch) or isAsciiDigit(ch)) ch else '_';
        if (normalized == '_' and (out.items.len == 0 or out.items[out.items.len - 1] == '_')) continue;
        try out.append(allocator, normalized);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(allocator, "app");
    return out.toOwnedSlice(allocator);
}

fn writeAngularFrontend(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames) !void {
    try app_dir.createDirPath(io, "frontend/src/app/home");
    const project_key = try angularProjectKey(allocator, names.package_name);
    defer allocator.free(project_key);

    const angular_json = try angularAngularJson(allocator, project_key);
    defer allocator.free(angular_json);

    const package_json = try angularPackageJson(allocator, names);
    defer allocator.free(package_json);

    const index_html = try angularIndexHtml(allocator, names.display_name);
    defer allocator.free(index_html);

    const home_html = try angularHomeHtml(allocator, names.display_name);
    defer allocator.free(home_html);

    try writeFile(app_dir, io, "frontend/angular.json", angular_json);
    try writeFile(app_dir, io, "frontend/package.json", package_json);
    try writeFile(app_dir, io, "frontend/tsconfig.json", angularTsConfigJson());
    try writeFile(app_dir, io, "frontend/tsconfig.app.json", angularTsConfigAppJson());
    try writeFile(app_dir, io, "frontend/src/main.ts", angularMainTs());
    try writeFile(app_dir, io, "frontend/src/index.html", index_html);
    try writeFile(app_dir, io, "frontend/src/styles.css", frontendStylesCss());
    try writeFile(app_dir, io, "frontend/src/app/app.config.ts", angularAppConfigTs());
    try writeFile(app_dir, io, "frontend/src/app/app.routes.ts", angularAppRoutesTs());
    try writeFile(app_dir, io, "frontend/src/app/app.ts", angularAppTs());
    try writeFile(app_dir, io, "frontend/src/app/home/home.ts", angularHomeTs());
    try writeFile(app_dir, io, "frontend/src/app/home/home.html", home_html);
    try writeFile(app_dir, io, "frontend/src/app/home/home.css", "");
}

fn angularAngularJson(allocator: std.mem.Allocator, project_key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{
        \\  "$schema": "./node_modules/@angular/cli/lib/config/schema.json",
        \\  "version": 1,
        \\  "newProjectRoot": "projects",
        \\  "projects": {{
        \\    "{s}": {{
        \\      "projectType": "application",
        \\      "root": "",
        \\      "sourceRoot": "src",
        \\      "prefix": "app",
        \\      "architect": {{
        \\        "build": {{
        \\          "builder": "@angular/build:application",
        \\          "options": {{
        \\            "outputPath": {{ "base": "dist", "browser": "" }},
        \\            "browser": "src/main.ts",
        \\            "tsConfig": "tsconfig.app.json",
        \\            "styles": ["src/styles.css"]
        \\          }},
        \\          "configurations": {{
        \\            "production": {{
        \\              "budgets": [
        \\                {{ "type": "initial", "maximumWarning": "500kB", "maximumError": "1MB" }},
        \\                {{ "type": "anyComponentStyle", "maximumWarning": "4kB", "maximumError": "8kB" }}
        \\              ],
        \\              "outputHashing": "all"
        \\            }},
        \\            "development": {{
        \\              "optimization": false,
        \\              "extractLicenses": false,
        \\              "sourceMap": true
        \\            }}
        \\          }},
        \\          "defaultConfiguration": "production"
        \\        }},
        \\        "serve": {{
        \\          "builder": "@angular/build:dev-server",
        \\          "options": {{ "host": "127.0.0.1" }},
        \\          "configurations": {{
        \\            "production": {{ "buildTarget": "{s}:build:production" }},
        \\            "development": {{ "buildTarget": "{s}:build:development" }}
        \\          }},
        \\          "defaultConfiguration": "development"
        \\        }}
        \\      }}
        \\    }}
        \\  }}
        \\}}
        \\
    , .{ project_key, project_key, project_key });
}

fn angularPackageJson(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  \"name\": ");
    try appendJsonString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\  "version": "0.1.0",
        \\  "private": true,
        \\  "scripts": {
        \\    "dev": "ng serve",
        \\    "build": "ng build"
        \\  },
        \\  "dependencies": {
        \\    "@angular/common": "^20.3.0",
        \\    "@angular/compiler": "^20.3.0",
        \\    "@angular/core": "^20.3.0",
        \\    "@angular/forms": "^20.3.0",
        \\    "@angular/platform-browser": "^20.3.0",
        \\    "@angular/router": "^20.3.0",
        \\    "rxjs": "~7.8.0",
        \\    "tslib": "^2.3.0"
        \\  },
        \\  "devDependencies": {
        \\    "@angular/build": "^20.3.26",
        \\    "@angular/cli": "^20.3.26",
        \\    "@angular/compiler-cli": "^20.3.0",
        \\    "typescript": "~5.9.2"
        \\  }
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn angularTsConfigJson() []const u8 {
    return
    \\{
    \\  "compileOnSave": false,
    \\  "compilerOptions": {
    \\    "strict": true,
    \\    "noImplicitOverride": true,
    \\    "noPropertyAccessFromIndexSignature": true,
    \\    "noImplicitReturns": true,
    \\    "noFallthroughCasesInSwitch": true,
    \\    "skipLibCheck": true,
    \\    "isolatedModules": true,
    \\    "experimentalDecorators": true,
    \\    "importHelpers": true,
    \\    "target": "ES2022",
    \\    "module": "preserve"
    \\  },
    \\  "angularCompilerOptions": {
    \\    "enableI18nLegacyMessageIdFormat": false,
    \\    "strictInjectionParameters": true,
    \\    "strictInputAccessModifiers": true,
    \\    "typeCheckHostBindings": true,
    \\    "strictTemplates": true
    \\  },
    \\  "files": [],
    \\  "references": [{ "path": "./tsconfig.app.json" }]
    \\}
    \\
    ;
}

fn angularTsConfigAppJson() []const u8 {
    return
    \\{
    \\  "extends": "./tsconfig.json",
    \\  "compilerOptions": {
    \\    "outDir": "./out-tsc/app",
    \\    "types": []
    \\  },
    \\  "include": ["src/**/*.ts"],
    \\  "exclude": ["src/**/*.spec.ts"]
    \\}
    \\
    ;
}

fn angularMainTs() []const u8 {
    return
    \\import { bootstrapApplication } from '@angular/platform-browser';
    \\import { appConfig } from './app/app.config';
    \\import { App } from './app/app';
    \\
    \\bootstrapApplication(App, appConfig).catch((err) => console.error(err));
    \\
    ;
}

fn angularAppConfigTs() []const u8 {
    return
    \\import {
    \\  ApplicationConfig,
    \\  provideBrowserGlobalErrorListeners,
    \\  provideZonelessChangeDetection,
    \\} from '@angular/core';
    \\import { provideRouter } from '@angular/router';
    \\
    \\import { routes } from './app.routes';
    \\
    \\export const appConfig: ApplicationConfig = {
    \\  providers: [
    \\    provideBrowserGlobalErrorListeners(),
    \\    provideZonelessChangeDetection(),
    \\    provideRouter(routes),
    \\  ],
    \\};
    \\
    ;
}

fn angularAppRoutesTs() []const u8 {
    return
    \\import { Routes } from '@angular/router';
    \\
    \\import { Home } from './home/home';
    \\
    \\export const routes: Routes = [
    \\  { path: '', pathMatch: 'full', component: Home },
    \\];
    \\
    ;
}

fn angularAppTs() []const u8 {
    return
    \\import { ChangeDetectionStrategy, Component } from '@angular/core';
    \\import { RouterOutlet } from '@angular/router';
    \\
    \\@Component({
    \\  selector: 'app-root',
    \\  changeDetection: ChangeDetectionStrategy.OnPush,
    \\  imports: [RouterOutlet],
    \\  template: '<router-outlet />',
    \\})
    \\export class App {}
    \\
    ;
}

fn angularHomeTs() []const u8 {
    return
    \\import { ChangeDetectionStrategy, Component, signal } from '@angular/core';
    \\
    \\@Component({
    \\  selector: 'app-home',
    \\  changeDetection: ChangeDetectionStrategy.OnPush,
    \\  templateUrl: './home.html',
    \\  styleUrl: './home.css',
    \\})
    \\export class Home {
    \\  protected readonly bridge = signal('zero' in globalThis ? 'available' : 'not enabled');
    \\}
    \\
    ;
}

fn angularIndexHtml(allocator: std.mem.Allocator, display_name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <title>
    );
    try appendXmlText(&out, allocator, display_name);
    try out.appendSlice(allocator,
        \\</title>
        \\  <base href="/">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\</head>
        \\<body>
        \\  <app-root></app-root>
        \\</body>
        \\</html>
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn angularHomeHtml(allocator: std.mem.Allocator, display_name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\<main>
        \\  <p class="eyebrow">zero-native + Angular</p>
        \\  <h1>
    );
    try appendXmlText(&out, allocator, display_name);
    try out.appendSlice(allocator,
        \\</h1>
        \\  <p class="lede">An Angular frontend running inside the system WebView.</p>
        \\  <div class="card">
        \\    <span>Native bridge</span>
        \\    <strong role="status" aria-live="polite">{{ bridge() }}</strong>
        \\  </div>
        \\</main>
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn writeNextFrontend(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames) !void {
    try app_dir.createDirPath(io, "frontend/app");
    const package_json = try nextPackageJson(allocator, names);
    defer allocator.free(package_json);
    try writeFile(app_dir, io, "frontend/package.json", package_json);
    try writeFile(app_dir, io, "frontend/next.config.js", nextConfig());
    try writeFile(app_dir, io, "frontend/tsconfig.json", nextTsconfig());
    const layout = try nextLayout(allocator, names);
    defer allocator.free(layout);
    try writeFile(app_dir, io, "frontend/app/layout.tsx", layout);
    const page = try nextPage(allocator, names);
    defer allocator.free(page);
    try writeFile(app_dir, io, "frontend/app/page.tsx", page);
    try writeFile(app_dir, io, "frontend/app/globals.css", frontendStylesCss());
}

fn writeViteFrontend(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames) !void {
    try app_dir.createDirPath(io, "frontend/src");
    const package_json = try vitePackageJson(allocator, names);
    defer allocator.free(package_json);
    const index_html = try viteIndexHtml(allocator, names);
    defer allocator.free(index_html);
    try writeFile(app_dir, io, "frontend/package.json", package_json);
    try writeFile(app_dir, io, "frontend/index.html", index_html);
    try writeFile(app_dir, io, "frontend/src/main.js", viteMainJs());
    try writeFile(app_dir, io, "frontend/src/styles.css", frontendStylesCss());
}

fn writeReactFrontend(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames) !void {
    try app_dir.createDirPath(io, "frontend/src");
    const package_json = try reactPackageJson(allocator, names);
    defer allocator.free(package_json);
    const index_html = try reactIndexHtml(allocator, names);
    defer allocator.free(index_html);
    const app_tsx = try reactAppTsx(allocator, names);
    defer allocator.free(app_tsx);
    try writeFile(app_dir, io, "frontend/package.json", package_json);
    try writeFile(app_dir, io, "frontend/vite.config.js", reactViteConfig());
    try writeFile(app_dir, io, "frontend/index.html", index_html);
    try writeFile(app_dir, io, "frontend/src/main.tsx", reactMainTsx());
    try writeFile(app_dir, io, "frontend/src/App.tsx", app_tsx);
    try writeFile(app_dir, io, "frontend/src/index.css", frontendStylesCss());
}

fn writeSvelteFrontend(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames) !void {
    try app_dir.createDirPath(io, "frontend/src");
    const package_json = try sveltePackageJson(allocator, names);
    defer allocator.free(package_json);
    const index_html = try svelteIndexHtml(allocator, names);
    defer allocator.free(index_html);
    try writeFile(app_dir, io, "frontend/package.json", package_json);
    try writeFile(app_dir, io, "frontend/svelte.config.js", svelteConfig());
    try writeFile(app_dir, io, "frontend/vite.config.js", svelteViteConfig());
    try writeFile(app_dir, io, "frontend/index.html", index_html);
    try writeFile(app_dir, io, "frontend/src/main.js", svelteMainJs());
    try writeFile(app_dir, io, "frontend/src/App.svelte", svelteAppComponent(names));
    try writeFile(app_dir, io, "frontend/src/app.css", frontendStylesCss());
}

fn writeVueFrontend(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames) !void {
    try app_dir.createDirPath(io, "frontend/src");
    const package_json = try vuePackageJson(allocator, names);
    defer allocator.free(package_json);
    const index_html = try vueIndexHtml(allocator, names);
    defer allocator.free(index_html);
    try writeFile(app_dir, io, "frontend/package.json", package_json);
    try writeFile(app_dir, io, "frontend/vite.config.js", vueViteConfig());
    try writeFile(app_dir, io, "frontend/index.html", index_html);
    try writeFile(app_dir, io, "frontend/src/main.js", vueMainJs());
    try writeFile(app_dir, io, "frontend/src/App.vue", vueAppComponent(names));
    try writeFile(app_dir, io, "frontend/src/style.css", frontendStylesCss());
}

fn nextPackageJson(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  \"name\": ");
    try appendJsonString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\  "private": true,
        \\  "version": "0.1.0",
        \\  "scripts": {
        \\    "dev": "next dev",
        \\    "build": "next build",
        \\    "start": "next start"
        \\  },
        \\  "dependencies": {
        \\    "next": "^16.2.6",
        \\    "react": "^19.2.6",
        \\    "react-dom": "^19.2.6"
        \\  },
        \\  "devDependencies": {
        \\    "@types/node": "^25.6.2",
        \\    "@types/react": "^19.2.14",
        \\    "@types/react-dom": "^19.2.3",
        \\    "typescript": "^6.0.3"
        \\  }
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn nextConfig() []const u8 {
    return
    \\/** @type {import('next').NextConfig} */
    \\const nextConfig = {
    \\  output: "export",
    \\};
    \\
    \\module.exports = nextConfig;
    \\
    ;
}

fn nextTsconfig() []const u8 {
    return
    \\{
    \\  "compilerOptions": {
    \\    "target": "ES2017",
    \\    "lib": ["dom", "dom.iterable", "esnext"],
    \\    "allowJs": true,
    \\    "skipLibCheck": true,
    \\    "strict": true,
    \\    "noEmit": true,
    \\    "esModuleInterop": true,
    \\    "module": "esnext",
    \\    "moduleResolution": "bundler",
    \\    "resolveJsonModule": true,
    \\    "isolatedModules": true,
    \\    "jsx": "react-jsx",
    \\    "incremental": true,
    \\    "plugins": [{ "name": "next" }],
    \\    "paths": { "@/*": ["./app/*"] }
    \\  },
    \\  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts", ".next/dev/types/**/*.ts"],
    \\  "exclude": ["node_modules"]
    \\}
    \\
    ;
}

fn nextLayout(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\import "./globals.css";
        \\
        \\export const metadata = {
        \\  title: "
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\",
        \\};
        \\
        \\export default function RootLayout({ children }: { children: React.ReactNode }) {
        \\  return (
        \\    <html lang="en">
        \\      <body>{children}</body>
        \\    </html>
        \\  );
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn nextPage(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\"use client";
        \\
        \\import { useEffect, useState } from "react";
        \\
        \\export default function Home() {
        \\  const [bridge, setBridge] = useState("checking...");
        \\
        \\  useEffect(() => {
        \\    setBridge((window as any).zero ? "available" : "not enabled");
        \\  }, []);
        \\
        \\  return (
        \\    <main>
        \\      <p className="eyebrow">zero-native + Next.js</p>
        \\      <h1>
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\</h1>
        \\      <p className="lede">A Next.js frontend running inside the system WebView.</p>
        \\      <div className="card">
        \\        <span>Native bridge</span>
        \\        <strong>{bridge}</strong>
        \\      </div>
        \\    </main>
        \\  );
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn vitePackageJson(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  \"name\": ");
    try appendJsonString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\  "private": true,
        \\  "version": "0.1.0",
        \\  "type": "module",
        \\  "scripts": {
        \\    "dev": "vite",
        \\    "build": "vite build",
        \\    "preview": "vite preview"
        \\  },
        \\  "devDependencies": {
        \\    "vite": "^8.0.11"
        \\  }
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn viteIndexHtml(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="UTF-8" />
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        \\    <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' http://127.0.0.1:5173 ws://127.0.0.1:5173" />
        \\    <title>
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\</title>
        \\  </head>
        \\  <body>
        \\    <main id="app">
        \\      <p class="eyebrow">zero-native + Vite</p>
        \\      <h1>
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\</h1>
        \\      <p class="lede">A minimal web frontend running inside the system WebView.</p>
        \\      <div class="card">
        \\        <span>Native bridge</span>
        \\        <strong id="bridge-status">checking...</strong>
        \\      </div>
        \\    </main>
        \\    <script type="module" src="/src/main.js"></script>
        \\  </body>
        \\</html>
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn viteMainJs() []const u8 {
    return
    \\import "./styles.css";
    \\
    \\const bridgeStatus = document.querySelector("#bridge-status");
    \\const hasBridge = typeof window !== "undefined" && Boolean(window.zero);
    \\
    \\bridgeStatus.textContent = hasBridge ? "available" : "not enabled";
    \\bridgeStatus.dataset.ready = "true";
    \\
    ;
}

fn frontendStylesCss() []const u8 {
    return
    \\:root {
    \\  color: #0f172a;
    \\  background: #f8fafc;
    \\  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    \\}
    \\
    \\body {
    \\  min-width: 320px;
    \\  min-height: 100vh;
    \\  margin: 0;
    \\  display: grid;
    \\  place-items: center;
    \\}
    \\
    \\main {
    \\  width: min(560px, calc(100vw - 48px));
    \\  padding: 32px;
    \\  border-radius: 24px;
    \\  background: white;
    \\  box-shadow: 0 24px 60px rgba(15, 23, 42, 0.14);
    \\}
    \\
    \\h1 {
    \\  margin: 0 0 12px;
    \\  font-size: clamp(2rem, 8vw, 4rem);
    \\  line-height: 1;
    \\}
    \\
    \\.eyebrow {
    \\  margin: 0 0 12px;
    \\  color: #2563eb;
    \\  font-weight: 700;
    \\  letter-spacing: 0.08em;
    \\  text-transform: uppercase;
    \\}
    \\
    \\.lede {
    \\  margin: 0 0 24px;
    \\  color: #475569;
    \\  line-height: 1.6;
    \\}
    \\
    \\.card {
    \\  display: flex;
    \\  align-items: center;
    \\  justify-content: space-between;
    \\  gap: 16px;
    \\  padding: 16px;
    \\  border: 1px solid #e2e8f0;
    \\  border-radius: 16px;
    \\  background: #f8fafc;
    \\}
    \\
    ;
}

fn reactPackageJson(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  \"name\": ");
    try appendJsonString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\  "private": true,
        \\  "version": "0.1.0",
        \\  "type": "module",
        \\  "scripts": {
        \\    "dev": "vite",
        \\    "build": "vite build",
        \\    "preview": "vite preview"
        \\  },
        \\  "dependencies": {
        \\    "react": "^19.2.6",
        \\    "react-dom": "^19.2.6"
        \\  },
        \\  "devDependencies": {
        \\    "@types/react": "^19.2.14",
        \\    "@types/react-dom": "^19.2.3",
        \\    "@vitejs/plugin-react": "^6.0.1",
        \\    "vite": "^8.0.11"
        \\  }
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn reactViteConfig() []const u8 {
    return
    \\import { defineConfig } from "vite";
    \\import react from "@vitejs/plugin-react";
    \\
    \\export default defineConfig({
    \\  plugins: [react()],
    \\});
    \\
    ;
}

fn reactIndexHtml(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="UTF-8" />
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        \\    <title>
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\</title>
        \\  </head>
        \\  <body>
        \\    <div id="root"></div>
        \\    <script type="module" src="/src/main.tsx"></script>
        \\  </body>
        \\</html>
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn reactMainTsx() []const u8 {
    return
    \\import { StrictMode } from "react";
    \\import { createRoot } from "react-dom/client";
    \\import App from "./App";
    \\import "./index.css";
    \\
    \\createRoot(document.getElementById("root")!).render(
    \\  <StrictMode>
    \\    <App />
    \\  </StrictMode>
    \\);
    \\
    ;
}

fn reactAppTsx(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\import { useEffect, useState } from "react";
        \\
        \\export default function App() {
        \\  const [bridge, setBridge] = useState("checking...");
        \\
        \\  useEffect(() => {
        \\    setBridge((window as any).zero ? "available" : "not enabled");
        \\  }, []);
        \\
        \\  return (
        \\    <main>
        \\      <p className="eyebrow">zero-native + React</p>
        \\      <h1>
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\</h1>
        \\      <p className="lede">A React frontend running inside the system WebView.</p>
        \\      <div className="card">
        \\        <span>Native bridge</span>
        \\        <strong>{bridge}</strong>
        \\      </div>
        \\    </main>
        \\  );
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn sveltePackageJson(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  \"name\": ");
    try appendJsonString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\  "private": true,
        \\  "version": "0.1.0",
        \\  "type": "module",
        \\  "scripts": {
        \\    "dev": "vite",
        \\    "build": "vite build",
        \\    "preview": "vite preview"
        \\  },
        \\  "dependencies": {
        \\    "svelte": "^5.55.5"
        \\  },
        \\  "devDependencies": {
        \\    "@sveltejs/vite-plugin-svelte": "^7.1.2",
        \\    "vite": "^8.0.11"
        \\  }
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn svelteViteConfig() []const u8 {
    return
    \\import { defineConfig } from "vite";
    \\import { svelte } from "@sveltejs/vite-plugin-svelte";
    \\
    \\export default defineConfig({
    \\  plugins: [svelte()],
    \\});
    \\
    ;
}

fn svelteConfig() []const u8 {
    return
    \\export default {};
    \\
    ;
}

fn svelteIndexHtml(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="UTF-8" />
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        \\    <title>
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\</title>
        \\  </head>
        \\  <body>
        \\    <div id="app"></div>
        \\    <script type="module" src="/src/main.js"></script>
        \\  </body>
        \\</html>
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn svelteMainJs() []const u8 {
    return
    \\import App from "./App.svelte";
    \\import "./app.css";
    \\
    \\const app = new App({ target: document.getElementById("app") });
    \\
    \\export default app;
    \\
    ;
}

fn svelteAppComponent(names: TemplateNames) []const u8 {
    _ = names;
    return
    \\<script>
    \\  import { onMount } from "svelte";
    \\
    \\  let bridge = $state("checking...");
    \\
    \\  onMount(() => {
    \\    bridge = window.zero ? "available" : "not enabled";
    \\  });
    \\</script>
    \\
    \\<main>
    \\  <p class="eyebrow">zero-native + Svelte</p>
    \\  <h1>App</h1>
    \\  <p class="lede">A Svelte frontend running inside the system WebView.</p>
    \\  <div class="card">
    \\    <span>Native bridge</span>
    \\    <strong>{bridge}</strong>
    \\  </div>
    \\</main>
    \\
    ;
}

fn vuePackageJson(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  \"name\": ");
    try appendJsonString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\  "private": true,
        \\  "version": "0.1.0",
        \\  "type": "module",
        \\  "scripts": {
        \\    "dev": "vite",
        \\    "build": "vite build",
        \\    "preview": "vite preview"
        \\  },
        \\  "dependencies": {
        \\    "vue": "^3.5.34"
        \\  },
        \\  "devDependencies": {
        \\    "@vitejs/plugin-vue": "^6.0.6",
        \\    "vite": "^8.0.11"
        \\  }
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn vueViteConfig() []const u8 {
    return
    \\import { defineConfig } from "vite";
    \\import vue from "@vitejs/plugin-vue";
    \\
    \\export default defineConfig({
    \\  plugins: [vue()],
    \\});
    \\
    ;
}

fn vueIndexHtml(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="UTF-8" />
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        \\    <title>
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\</title>
        \\  </head>
        \\  <body>
        \\    <div id="app"></div>
        \\    <script type="module" src="/src/main.js"></script>
        \\  </body>
        \\</html>
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn vueMainJs() []const u8 {
    return
    \\import { createApp } from "vue";
    \\import App from "./App.vue";
    \\import "./style.css";
    \\
    \\createApp(App).mount("#app");
    \\
    ;
}

fn vueAppComponent(names: TemplateNames) []const u8 {
    _ = names;
    return
    \\<script setup>
    \\import { ref, onMounted } from "vue";
    \\
    \\const bridge = ref("checking...");
    \\
    \\onMounted(() => {
    \\  bridge.value = window.zero ? "available" : "not enabled";
    \\});
    \\</script>
    \\
    \\<template>
    \\  <main>
    \\    <p class="eyebrow">zero-native + Vue</p>
    \\    <h1>App</h1>
    \\    <p class="lede">A Vue frontend running inside the system WebView.</p>
    \\    <div class="card">
    \\      <span>Native bridge</span>
    \\      <strong>{{ bridge }}</strong>
    \\    </div>
    \\  </main>
    \\</template>
    \\
    ;
}

fn readme(allocator: std.mem.Allocator, names: TemplateNames, framework_path: []const u8, frontend: Frontend) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# ");
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\
        \\
        \\A minimal zero-native desktop app with a web frontend.
        \\
        \\## Setup
        \\
        \\`zig build dev`, `zig build run`, and `zig build package` install frontend dependencies automatically. To install them explicitly, run:
        \\
        \\```sh
        \\npm install --prefix frontend
        \\```
        \\
        \\The generated build defaults to this zero-native framework path:
        \\
        \\```text
    );
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, framework_path);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator,
        \\
        \\```
        \\
        \\Override it with `-Dzero-native-path=/path/to/zero-native` if you move this app.
        \\
        \\## Commands
        \\
        \\```sh
        \\zig build dev
        \\zig build run
        \\zig build test
        \\zig build package
        \\zero-native doctor --manifest app.zon
        \\```
        \\
        \\`zig build dev` starts the frontend dev server from `app.zon`, waits for it, and launches the native shell with `ZERO_NATIVE_FRONTEND_URL`.
        \\
        \\Frontend:
        \\
        \\- Type: 
    );
    try out.appendSlice(allocator, @tagName(frontend));
    try out.appendSlice(allocator,
        \\
        \\- Production assets: `
    );
    try out.appendSlice(allocator, frontend.distDir());
    try out.appendSlice(allocator,
        \\`
        \\- Dev URL: `
    );
    try out.appendSlice(allocator, frontend.devUrl());
    try out.appendSlice(allocator,
        \\`
        \\
        \\## Web Engines
        \\
        \\The generated app defaults to the system WebView. On macOS you can switch to Chromium/CEF with:
        \\
        \\```sh
        \\zero-native cef install
        \\zig build run -Dplatform=macos -Dweb-engine=chromium
        \\```
        \\
        \\`zero-native cef install` downloads zero-native's prepared CEF runtime, including the native wrapper library.
        \\
        \\For one-command local setup, opt into build-time install:
        \\
        \\```sh
        \\zig build run -Dplatform=macos -Dweb-engine=chromium -Dcef-auto-install=true
        \\```
        \\
        \\Use `-Dcef-dir=/path/to/cef` when you keep CEF outside the platform default under `third_party/cef`.
        \\
        \\```sh
        \\zero-native doctor --web-engine chromium
        \\```
        \\
        \\Diagnostics:
        \\
        \\- Set `ZERO_NATIVE_LOG_DIR` to override the platform log directory during development.
        \\- Set `ZERO_NATIVE_LOG_FORMAT=text|jsonl` to choose persistent log format.
        \\
    );
    return out.toOwnedSlice(allocator);
}

test "template strings are non-empty" {
    const names = try TemplateNames.init(std.testing.allocator, "app");
    defer names.deinit(std.testing.allocator);
    const build_zig = try buildZig(std.testing.allocator, names, "..", .vite);
    defer std.testing.allocator.free(build_zig);
    const main_zig = try mainZig(std.testing.allocator, names, .vite);
    defer std.testing.allocator.free(main_zig);
    try std.testing.expect(build_zig.len > 0);
    try std.testing.expect(main_zig.len > 0);
    try std.testing.expect(runnerZig().len > 0);
}

test "template names are sanitized for generated metadata" {
    const names = try TemplateNames.init(std.testing.allocator, "My Cool_App!");
    defer names.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("my-cool-app", names.package_name);
    try std.testing.expectEqualStrings("my_cool_app", names.module_name);
    try std.testing.expectEqualStrings("My Cool App", names.display_name);
    try std.testing.expectEqualStrings("dev.zero_native.my-cool-app", names.app_id);
}

test "template fingerprint includes package name checksum" {
    try std.testing.expectEqual(@as(u64, 0x92a6f71c5a707070), fingerprintForName("test_vite_init_smoke"));
}

test "writeDefaultApp emits Vite project files" {
    const destination = ".zig-cache/test-vite-init-template";
    try writeDefaultApp(std.testing.allocator, std.testing.io, destination, .{ .app_name = "My App", .framework_path = ".", .frontend = .vite });

    const app_zon_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "app.zon");
    defer std.testing.allocator.free(app_zon_text);
    const build_zig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "build.zig");
    defer std.testing.allocator.free(build_zig_text);
    const main_zig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "src/main.zig");
    defer std.testing.allocator.free(main_zig_text);
    const package_json_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "frontend/package.json");
    defer std.testing.allocator.free(package_json_text);
    const main_js_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "frontend/src/main.js");
    defer std.testing.allocator.free(main_js_text);

    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, ".frontend") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, "frontend/dist") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, "npm") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "frontend-install") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "\"npm\", \"install\", \"--prefix\", \"frontend\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "frontend-build") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "frontend_build.step.dependOn(&frontend_install.step)") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "\"zero-native\", \"dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "dev.step.dependOn(&frontend_install.step)") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "chromium") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "cef-dir") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "src/platform/macos/cef_host.mm") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "src/platform/linux/gtk_host.c") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_zig_text, "frontend/dist") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_zig_text, "127.0.0.1:5173") != null);
    try std.testing.expect(std.mem.indexOf(u8, package_json_text, "\"vite\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_js_text, "window.zero") != null);
}

test "writeDefaultApp emits frontend-specific Next paths" {
    const destination = ".zig-cache/test-next-init-template";
    try writeDefaultApp(std.testing.allocator, std.testing.io, destination, .{ .app_name = "Next App", .framework_path = ".", .frontend = .next });

    const app_zon_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "app.zon");
    defer std.testing.allocator.free(app_zon_text);
    const build_zig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "build.zig");
    defer std.testing.allocator.free(build_zig_text);
    const main_zig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "src/main.zig");
    defer std.testing.allocator.free(main_zig_text);
    const tsconfig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "frontend/tsconfig.json");
    defer std.testing.allocator.free(tsconfig_text);

    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, "frontend/out") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, "127.0.0.1:3000") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "frontend/out") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_zig_text, "frontend/out") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_zig_text, "127.0.0.1:3000") != null);
    try std.testing.expect(std.mem.indexOf(u8, tsconfig_text, "\"@/*\": [\"./app/*\"]") != null);
}

test "writeDefaultApp emits frontend-specific Angular paths" {
    const destination = ".zig-cache/test-angular-init-template";
    try writeDefaultApp(std.testing.allocator, std.testing.io, destination, .{ .app_name = "Angular App", .framework_path = ".", .frontend = .angular });

    const app_zon_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "app.zon");
    defer std.testing.allocator.free(app_zon_text);
    const angular_json_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "frontend/angular.json");
    defer std.testing.allocator.free(angular_json_text);
    const main_zig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "src/main.zig");
    defer std.testing.allocator.free(main_zig_text);
    const package_json_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "frontend/package.json");
    defer std.testing.allocator.free(package_json_text);
    const app_ts_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "frontend/src/app/app.ts");
    defer std.testing.allocator.free(app_ts_text);
    const home_html_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "frontend/src/app/home/home.html");
    defer std.testing.allocator.free(home_html_text);

    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, "frontend/dist") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, "127.0.0.1:4200") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_zig_text, "frontend/dist") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_zig_text, "127.0.0.1:4200") != null);
    try std.testing.expect(std.mem.indexOf(u8, angular_json_text, "\"base\": \"dist\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, angular_json_text, "\"browser\": \"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, angular_json_text, "\"host\": \"127.0.0.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, angular_json_text, "zone.js") == null);
    try std.testing.expect(std.mem.indexOf(u8, app_ts_text, "ChangeDetectionStrategy.OnPush") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_ts_text, "standalone: true") == null);
    try std.testing.expect(std.mem.indexOf(u8, home_html_text, "role=\"status\" aria-live=\"polite\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, package_json_text, "\"@angular/core\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, package_json_text, "\"zone.js\"") == null);
}

test "angularProjectKey emits Angular-safe target names" {
    const key = try angularProjectKey(std.testing.allocator, "123 bad.name/@scope");
    defer std.testing.allocator.free(key);

    try std.testing.expectEqualStrings("app_123_bad_name_scope", key);
}

fn normalizePackageName(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var last_separator = false;
    for (value) |ch| {
        if (isAsciiAlpha(ch) or isAsciiDigit(ch)) {
            try out.append(allocator, std.ascii.toLower(ch));
            last_separator = false;
        } else if (!last_separator and out.items.len > 0) {
            try out.append(allocator, '-');
            last_separator = true;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(allocator, "zero-native-app");
    return out.toOwnedSlice(allocator);
}

fn normalizeModuleName(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const max_zig_package_name_len = 32;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (value.len == 0 or isAsciiDigit(value[0])) try out.appendSlice(allocator, "app_");
    for (value) |ch| {
        if (out.items.len >= max_zig_package_name_len) break;
        if (isAsciiAlpha(ch) or isAsciiDigit(ch)) {
            try out.append(allocator, std.ascii.toLower(ch));
        } else {
            try out.append(allocator, '_');
        }
    }
    return out.toOwnedSlice(allocator);
}

test "normalizeModuleName caps Zig package names" {
    const module_name = try normalizeModuleName(std.testing.allocator, "scaffold-package-smoke-1778284313");
    defer std.testing.allocator.free(module_name);

    try std.testing.expect(module_name.len <= 32);
    try std.testing.expectEqualStrings("scaffold_package_smoke_177828431", module_name);
}

fn displayName(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var start_word = true;
    for (value) |ch| {
        if (ch == '-') {
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(allocator, ' ');
            start_word = true;
            continue;
        }
        if (start_word and isAsciiAlpha(ch)) {
            try out.append(allocator, std.ascii.toUpper(ch));
        } else {
            try out.append(allocator, ch);
        }
        start_word = false;
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "zero-native app");
    return out.toOwnedSlice(allocator);
}

fn fingerprintForName(name: []const u8) u64 {
    const checksum: u64 = std.hash.Crc32.hash(name);
    return (checksum << 32) | 0x5a707070;
}

fn defaultFrameworkPath(allocator: std.mem.Allocator, io: std.Io, destination: []const u8, framework_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(framework_path)) {
        return allocator.dupe(u8, framework_path);
    }
    if (std.fs.path.isAbsolute(destination)) {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        return std.fs.path.join(allocator, &.{ cwd, framework_path });
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var destination_parts = std.mem.tokenizeAny(u8, destination, "/\\");
    while (destination_parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) continue;
        if (out.items.len > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, "..");
    }

    var framework_parts = std.mem.tokenizeAny(u8, framework_path, "/\\");
    while (framework_parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (part.len == 0) continue;
        if (out.items.len > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }

    if (out.items.len == 0) try out.append(allocator, '.');
    return out.toOwnedSlice(allocator);
}

fn appendZigString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try appendEscapedString(out, allocator, value);
}

fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try appendEscapedString(out, allocator, value);
}

fn appendXmlText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, ch),
        }
    }
}

fn appendEscapedString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
}

fn isAsciiAlpha(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

fn isAsciiDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn readTestFile(allocator: std.mem.Allocator, io: std.Io, root: []const u8, path: []const u8) ![]u8 {
    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer root_dir.close(io);
    var file = try root_dir.openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
}
