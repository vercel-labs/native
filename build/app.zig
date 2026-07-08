//! Framework build helper: `addApp` gives a markup/builder app a complete
//! build (exe, run, test) from a ~5-line build.zig. The app supplies
//! src/main.zig, app.zon, and assets; the runner and all framework modules
//! come from the native-sdk dependency.

const std = @import("std");

const PlatformOption = enum {
    auto,
    null,
    macos,
    linux,
    windows,
};

const TraceOption = enum {
    off,
    events,
    runtime,
    all,
};

const WebEngineOption = enum {
    system,
    chromium,
};

pub const AppOptions = struct {
    name: []const u8,
    /// App entry point; defaults to src/main.zig (relative to `app_root`).
    main: []const u8 = "src/main.zig",
    /// Root of the app source tree, relative to the build root. "." for a
    /// build.zig that lives in the app directory (every ejected app). The
    /// CLI's generated build graph under `<app>/.native/build/` passes
    /// "../.." so `src/`, `app.zon`, and `assets/` keep resolving in the
    /// app directory rather than the cache directory.
    app_root: []const u8 = ".",
};

/// The `native_sdk_app_*` C ABI every embed static library exports.
pub const mobile_export_symbol_names = [_][]const u8{
    "native_sdk_app_create",
    "native_sdk_app_destroy",
    "native_sdk_app_start",
    "native_sdk_app_activate",
    "native_sdk_app_deactivate",
    "native_sdk_app_stop",
    "native_sdk_app_resize",
    "native_sdk_app_viewport",
    "native_sdk_app_viewport_state",
    "native_sdk_app_gpu_frame_state",
    "native_sdk_app_text_input_state",
    "native_sdk_app_set_text_measure",
    "native_sdk_app_set_audio_service",
    "native_sdk_app_audio_event",
    "native_sdk_app_set_image_service",
    "native_sdk_app_set_automation_dir",
    "native_sdk_app_touch",
    "native_sdk_app_scroll",
    "native_sdk_app_key",
    "native_sdk_app_text",
    "native_sdk_app_ime",
    "native_sdk_app_command",
    "native_sdk_app_frame",
    "native_sdk_app_chrome_tab_count",
    "native_sdk_app_chrome_tab_at",
    "native_sdk_app_chrome_primary_action",
    "native_sdk_app_chrome_selected_tab",
    "native_sdk_app_chrome_navigation_depth",
    "native_sdk_app_chrome_navigation_back_command",
    "native_sdk_app_chrome_icon_pixels",
    "native_sdk_app_set_form_factor",
    "native_sdk_app_set_chrome_tabs_projected",
    "native_sdk_app_set_asset_root",
    "native_sdk_app_set_asset_entry",
    "native_sdk_app_last_command_count",
    "native_sdk_app_last_command_name",
    "native_sdk_app_last_error_name",
    "native_sdk_app_widget_semantics_count",
    "native_sdk_app_widget_semantics_at",
    "native_sdk_app_widget_semantics_by_id",
    "native_sdk_app_widget_text_geometry",
    "native_sdk_app_widget_action",
    "native_sdk_app_render_pixel_size",
    "native_sdk_app_render_pixels",
    "native_sdk_app_render_pixels_damage",
};

pub const MobileSceneOption = enum {
    /// The user app's UiApp on a gpu_surface view (window 1,
    /// "mobile-surface"), pumped by the host's frame callback.
    canvas,
    /// The fixed WebView shell the ios/android/mobile-shell examples embed
    /// today; the app module is not compiled in.
    webview,
};

pub const MobileLibOptions = struct {
    name: []const u8,
    /// Mobile app entry (the `"app"` module the embed host drives); must
    /// declare `Model`, `Msg`, `initModel`, and `mobileOptions` — see
    /// `src/embed/ui_host.zig`. Ignored for `.scene = .webview`.
    main: []const u8 = "src/main.zig",
    scene: MobileSceneOption = .canvas,
};

/// Mobile counterpart of `addApp`: produce the embed static library
/// (`native_sdk_app_*` C ABI) compiled with the user's UiApp. Call it from
/// a standalone build.zig (it registers the standard `target`/`optimize`
/// options itself).
pub fn addMobileLib(b: *std.Build, dep: *std.Build.Dependency, options: MobileLibOptions) void {
    const target = nativeSdkTarget(b);
    const optimize_request = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size");
    const optimize = exampleOptimizeMode(b, optimize_request, .Debug);
    addMobileLibWithTarget(b, dep, target, optimize, options);
}

/// The mobile-lib wiring behind `addMobileLib`, for builds that already
/// resolved `target`/`optimize` (`addAppArtifacts` registers the `lib`
/// step through this for iOS/Android targets, so every standard app —
/// generated graph or ejected `addApp` — can produce the embed library
/// with nothing but `-Dtarget`).
fn addMobileLibWithTarget(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: MobileLibOptions) void {
    const native_sdk_mod = nativeSdkModule(b, dep, target, optimize);
    // Android hosts load the embed lib inside a shared object
    // (System.loadLibrary / NativeActivity), so every object must be PIC —
    // without it Zig emits local-exec TLS relocations (R_AARCH64_TLSLE_*)
    // that the NDK linker rejects when producing the shim .so. Imported
    // modules leave `pic` null and inherit this from the root module.
    const pic: ?bool = if (target.result.abi.isAndroid()) true else null;
    const exports_mod = b.createModule(.{
        .root_source_file = dep.path(switch (options.scene) {
            .canvas => "src/embed/app_exports.zig",
            .webview => "src/embed/c_exports.zig",
        }),
        .target = target,
        .optimize = optimize,
        .pic = pic,
    });
    exports_mod.addImport("native_sdk", native_sdk_mod);
    if (options.scene == .canvas) {
        const app_mod = localModule(b, target, optimize, options.main);
        app_mod.addImport("native_sdk", native_sdk_mod);
        exports_mod.addImport("app", app_mod);
    }
    exports_mod.export_symbol_names = &mobile_export_symbol_names;

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = options.name,
        .root_module = exports_mod,
        // The embed C ABI (`native_sdk_app_viewport`) is exactly the
        // f32-heavy SysV signature Zig 0.16.0's self-hosted x86_64 backend
        // miscompiles (see useLlvmWorkaround in the framework build.zig):
        // clang-compiled hosts calling a self-hosted Debug lib receive
        // corrupted inset/keyboard floats on x86_64 (Android emulators,
        // Intel simulators). Force LLVM there; Release already uses it.
        .use_llvm = useLlvmWorkaround(target),
    });
    b.installArtifact(lib);

    const lib_step = b.step("lib", "Build the mobile embed static library");
    lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step);
}

/// The pieces `addApp` wires, for callers that extend the standard app
/// build (extra native sources, frameworks, post-build steps such as
/// entitlement signing). `install` is the artifact-install step behind the
/// default `zig build`; append dependencies to it and to `run` to order
/// work between the emitted binary and its consumers.
pub const AppArtifacts = struct {
    exe: *std.Build.Step.Compile,
    tests: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
    run: *std.Build.Step.Run,
};

pub fn addApp(b: *std.Build, dep: *std.Build.Dependency, app_options: AppOptions) void {
    _ = addAppArtifacts(b, dep, app_options);
}

pub fn addAppArtifacts(b: *std.Build, dep: *std.Build.Dependency, app_options: AppOptions) AppArtifacts {
    const target = nativeSdkTarget(b);
    const optimize_request = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size");
    const optimize = exampleOptimizeMode(b, optimize_request, .Debug);
    const app_optimize = exampleOptimizeMode(b, optimize_request, .ReleaseFast);

    // Mobile targets get the embed static library as a `lib` step: the
    // artifact the toolkit-owned iOS host (and any hand-written shim)
    // links, so `native dev|package --target ios` works against every
    // standard app build — generated graph or ejected — with nothing but
    // `-Dtarget`. Desktop targets keep the step absent.
    if (target.result.os.tag == .ios or target.result.abi.isAndroid()) {
        addMobileLibWithTarget(b, dep, target, optimize, .{
            .name = app_options.name,
            .main = appPath(b, app_options.app_root, app_options.main),
        });
    }
    const platform_option = b.option(PlatformOption, "platform", "Desktop backend: auto, null, macos, linux, windows") orelse .auto;
    const trace_option = b.option(TraceOption, "trace", "Trace output: off, events, runtime, all") orelse .events;
    const debug_overlay = b.option(bool, "debug-overlay", "Enable debug overlay output") orelse false;
    const automation_enabled = b.option(bool, "automation", "Enable Native SDK automation artifacts") orelse false;
    const js_bridge_enabled = b.option(bool, "js-bridge", "Enable optional JavaScript bridge stubs") orelse false;
    const web_engine_override = b.option(WebEngineOption, "web-engine", "Override app.zon web engine: system, chromium");
    const cef_dir_override = b.option([]const u8, "cef-dir", "Override CEF root directory for Chromium builds");
    const cef_auto_install_override = b.option(bool, "cef-auto-install", "Override app.zon CEF auto-install setting");
    const selected_platform: PlatformOption = switch (platform_option) {
        .auto => if (target.result.os.tag == .macos) .macos else if (target.result.os.tag == .linux) .linux else if (target.result.os.tag == .windows) .windows else .null,
        else => platform_option,
    };
    if (selected_platform == .macos and target.result.os.tag != .macos) {
        @panic("-Dplatform=macos requires a macOS target");
    }
    if (selected_platform == .linux and target.result.os.tag != .linux) {
        @panic("-Dplatform=linux requires a Linux target");
    }
    if (selected_platform == .windows and target.result.os.tag != .windows) {
        @panic("-Dplatform=windows requires a Windows target");
    }
    const app_web_engine = appWebEngineConfig(b, app_options.app_root);
    const web_engine = web_engine_override orelse app_web_engine.web_engine;
    const cef_dir = cef_dir_override orelse defaultCefDir(selected_platform, app_web_engine.cef_dir);
    const cef_auto_install = cef_auto_install_override orelse app_web_engine.cef_auto_install;
    if (web_engine == .chromium and selected_platform != .macos) {
        @panic("-Dweb-engine=chromium currently requires -Dplatform=macos");
    }

    const options = b.addOptions();
    options.addOption([]const u8, "platform", switch (selected_platform) {
        .auto => unreachable,
        .null => "null",
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
    });
    options.addOption([]const u8, "trace", @tagName(trace_option));
    options.addOption([]const u8, "web_engine", @tagName(web_engine));
    options.addOption(bool, "debug_overlay", debug_overlay);
    options.addOption(bool, "automation", automation_enabled);
    options.addOption(bool, "js_bridge", js_bridge_enabled);
    const options_mod = options.createModule();

    const app_mod = appModule(b, dep, target, app_optimize, app_options, options_mod);
    const exe = b.addExecutable(.{
        .name = app_options.name,
        .root_module = app_mod,
    });
    linkPlatform(b, dep, target, app_mod, exe, selected_platform, web_engine, cef_dir, cef_auto_install);
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    addCefRuntimeRunFiles(b, target, run, exe, web_engine, cef_dir);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run.step);

    const test_app_mod = if (app_optimize == optimize) app_mod else appModule(b, dep, target, optimize, app_options, options_mod);
    const tests = b.addTest(.{ .root_module = test_app_mod, .use_llvm = useLlvmWorkaround(target) });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // `zig build model-contract`: reflect the app's Model/Msg into
    // zig-out/model-contract.zon so `native check` can verify markup
    // bindings against the app's real surface without compiling the app.
    // The artifact carries a hash over the app's Zig sources; the checker
    // degrades to structural checking when it goes stale. Apps without a
    // pub Model/Msg pair make this a silent no-op. The test step refreshes
    // the artifact too, so CI-checked apps always hold a fresh one.
    const contract_root = b.addWriteFiles().add("model_contract_emit.zig",
        \\//! Generated by the app build: emits the model contract artifact
        \\//! (see the toolkit's ui_markup_contract.zig).
        \\const std = @import("std");
        \\const native_sdk = @import("native_sdk");
        \\const app = @import("app");
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    try native_sdk.canvas.emitModelContractMain(app, init);
        \\}
        \\
    );
    // The emit root must share the app module's native_sdk instance so
    // the Msg payload types it classifies are the same types the app
    // declares its variants with.
    const contract_mod = b.createModule(.{
        .root_source_file = contract_root,
        .target = target,
        .optimize = optimize,
    });
    contract_mod.addImport("app", test_app_mod);
    if (test_app_mod.import_table.get("native_sdk")) |sdk_mod| {
        contract_mod.addImport("native_sdk", sdk_mod);
    }
    const contract_exe = b.addExecutable(.{
        .name = b.fmt("{s}-model-contract", .{app_options.name}),
        .root_module = contract_mod,
        .use_llvm = useLlvmWorkaround(target),
    });
    const contract_run = b.addRunArtifact(contract_exe);
    contract_run.setCwd(b.path(app_options.app_root));
    contract_run.addArgs(&.{ "--src", "src", "--out", "zig-out/model-contract.zon" });
    contract_run.has_side_effects = true;
    const contract_step = b.step("model-contract", "Emit zig-out/model-contract.zon for `native check`");
    contract_step.dependOn(&contract_run.step);
    test_step.dependOn(&contract_run.step);

    // `zig build package`: bundle the built binary through the `native`
    // CLI (built from the native_sdk dependency), so a scaffolded app can
    // package itself without locating the CLI by hand.
    const host_os = b.graph.host.result.os.tag;
    const package_target: ?[]const u8 = switch (host_os) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => null,
    };
    if (package_target) |package_target_name| {
        const package_run = b.addRunArtifact(dep.artifact("native"));
        package_run.addArgs(&.{ "package", "--target", package_target_name, "--manifest", "app.zon", "--output" });
        package_run.addArg(if (host_os == .macos)
            b.fmt("zig-out/package/{s}.app", .{app_options.name})
        else
            b.fmt("zig-out/package/{s}", .{package_target_name}));
        package_run.addArg("--binary");
        package_run.addFileArg(exe.getEmittedBin());
        // The archive and report names carry an optimize label; this
        // build graph knows the packaged binary's REAL mode, so forward
        // it instead of letting the CLI assume one.
        package_run.addArgs(&.{ "--optimize", @tagName(app_optimize) });
        package_run.has_side_effects = true;
        const package_step = b.step("package", "Create a distributable package via the native CLI");
        package_step.dependOn(&package_run.step);
    }

    return .{ .exe = exe, .tests = tests, .install = install, .run = run };
}

/// Zig 0.16.0's self-hosted x86_64 backend miscompiles the SysV C calling
/// convention for f32-heavy signatures with interleaved pointer arguments
/// (`native_sdk_app_viewport`: 11 f32s + 2 pointers): both the caller and
/// the callee place/read the wrong registers and stack slots, so safe-area
/// insets arrive as garbage on x86_64 Debug builds while every LLVM-backed
/// build is correct. Minimal repro (fails under `zig test`, passes with
/// `-fllvm` on x86_64-linux):
///
///   fn take(a: ?*anyopaque, w: f32, h: f32, s: f32, p: ?*anyopaque,
///           t: f32, r: f32, bo: f32, l: f32, kt: f32, kr: f32, kb: f32,
///           kl: f32) callconv(.c) void { ... }
///
/// Force the LLVM backend on x86_64 until the upstream backend is fixed;
/// Release modes already default to LLVM, so this only changes Debug.
pub fn useLlvmWorkaround(target: std.Build.ResolvedTarget) ?bool {
    return if (target.result.cpu.arch == .x86_64) true else null;
}

fn exampleOptimizeMode(b: *std.Build, requested: ?std.builtin.OptimizeMode, default_mode: std.builtin.OptimizeMode) std.builtin.OptimizeMode {
    if (requested) |mode| return mode;
    return switch (b.release_mode) {
        .off => default_mode,
        .any, .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
        .small => .ReleaseSmall,
    };
}

fn appModule(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, app_options: AppOptions, options_mod: *std.Build.Module) *std.Build.Module {
    const native_sdk_mod = nativeSdkModule(b, dep, target, optimize);
    const runner_mod = b.createModule(.{
        .root_source_file = dep.path("src/app_runner/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    runner_mod.addImport("native_sdk", native_sdk_mod);
    runner_mod.addImport("build_options", options_mod);
    runner_mod.addImport("app_manifest_zon", b.createModule(.{ .root_source_file = b.path(appPath(b, app_options.app_root, "app.zon")) }));

    const app_mod = localModule(b, target, optimize, appPath(b, app_options.app_root, app_options.main));
    app_mod.addImport("native_sdk", native_sdk_mod);
    app_mod.addImport("runner", runner_mod);
    return app_mod;
}

fn nativeSdkTarget(b: *std.Build) std.Build.ResolvedTarget {
    const target = b.standardTargetOptions(.{});
    if (target.result.os.tag != .macos) return target;

    if (b.sysroot == null) {
        b.sysroot = macosSdkPath(b) orelse b.sysroot;
    }

    var query = target.query;
    query.os_tag = .macos;
    query.os_version_min = .{ .semver = .{ .major = 11, .minor = 0, .patch = 0 } };
    return b.resolveTargetQuery(query);
}

fn macosSdkPath(b: *std.Build) ?[]const u8 {
    if (b.graph.environ_map.get("SDKROOT")) |sdkroot| {
        if (sdkroot.len > 0) return sdkroot;
    }

    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer b.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        b.allocator.free(result.stdout);
        return null;
    }
    return std.mem.trimEnd(u8, result.stdout, "\r\n");
}

fn localModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
}

fn nativeSdkModule(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const geometry_mod = externalModule(b, dep, target, optimize, "src/primitives/geometry/root.zig");
    const assets_mod = externalModule(b, dep, target, optimize, "src/primitives/assets/root.zig");
    const app_dirs_mod = externalModule(b, dep, target, optimize, "src/primitives/app_dirs/root.zig");
    const trace_mod = externalModule(b, dep, target, optimize, "src/primitives/trace/root.zig");
    const app_manifest_mod = externalModule(b, dep, target, optimize, "src/primitives/app_manifest/root.zig");
    const diagnostics_mod = externalModule(b, dep, target, optimize, "src/primitives/diagnostics/root.zig");
    const platform_info_mod = externalModule(b, dep, target, optimize, "src/primitives/platform_info/root.zig");
    const json_mod = externalModule(b, dep, target, optimize, "src/primitives/json/root.zig");
    const canvas_mod = externalModule(b, dep, target, optimize, "src/primitives/canvas/root.zig");
    canvas_mod.addImport("geometry", geometry_mod);
    canvas_mod.addImport("json", json_mod);
    const debug_mod = externalModule(b, dep, target, optimize, "src/debug/root.zig");
    debug_mod.addImport("app_dirs", app_dirs_mod);
    debug_mod.addImport("trace", trace_mod);

    const native_sdk_mod = externalModule(b, dep, target, optimize, "src/root.zig");
    native_sdk_mod.addImport("geometry", geometry_mod);
    native_sdk_mod.addImport("assets", assets_mod);
    native_sdk_mod.addImport("app_dirs", app_dirs_mod);
    native_sdk_mod.addImport("trace", trace_mod);
    native_sdk_mod.addImport("app_manifest", app_manifest_mod);
    native_sdk_mod.addImport("diagnostics", diagnostics_mod);
    native_sdk_mod.addImport("platform_info", platform_info_mod);
    native_sdk_mod.addImport("json", json_mod);
    native_sdk_mod.addImport("canvas", canvas_mod);
    return native_sdk_mod;
}

fn externalModule(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = dep.path(path),
        .target = target,
        .optimize = optimize,
    });
}

// -fno-sanitize=builtin on every ObjC compile: Zig 0.16.0's Debug UBSan
// aborts any process whose first dispatch_once runs — the macOS SDK's
// inline `_dispatch_once` ends in `__builtin_assume(*predicate == ~0l)`
// (dispatch/once.h), Zig's bundled clang instruments that builtin, and the
// check fires spuriously at startup; zig's ubsan_rt then cannot even decode
// the report ("invalid enum value" / "passing zero to clz()" panics).
// Reproduced with a 10-line `zig cc` program against both the 14.5 and
// 26.0 SDKs. Release builds never hit it (no UBSan), which is why only
// Debug-built examples (standardOptimizeOption default) crashed.
fn linkPlatform(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, app_mod: *std.Build.Module, exe: *std.Build.Step.Compile, platform: PlatformOption, web_engine: WebEngineOption, cef_dir: []const u8, cef_auto_install: bool) void {
    if (platform == .macos) {
        switch (web_engine) {
            .system => {
                const sdk_include = if (b.sysroot) |sysroot| b.fmt("-I{s}/usr/include", .{sysroot}) else "";
                const flags: []const []const u8 = if (b.sysroot) |sysroot| &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=11.0", "-isysroot", sysroot, sdk_include } else &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=11.0" };
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/macos/appkit_host.m"), .flags = flags });
                app_mod.linkFramework("WebKit", .{});
            },
            .chromium => {
                const cef_check = addCefCheck(b, target, cef_dir);
                if (cef_auto_install) {
                    const cef_auto = b.addSystemCommand(&.{ "native", "cef", "install", "--dir", cef_dir });
                    cef_check.step.dependOn(&cef_auto.step);
                }
                exe.step.dependOn(&cef_check.step);
                const include_arg = b.fmt("-I{s}", .{cef_dir});
                const define_arg = b.fmt("-DNATIVE_SDK_CEF_DIR=\"{s}\"", .{cef_dir});
                // The SDK's usr/include must stay a system include dir (searched after zig's
                // bundled libc++/libc headers). A plain -I shadows libc++'s <string.h>/<math.h>
                // wrappers in ObjC++ and surfaces SDK nullability gaps as a diagnostic flood.
                const sdk_include = if (b.sysroot) |sysroot| b.fmt("-isystem{s}/usr/include", .{sysroot}) else "";
                const flags: []const []const u8 = if (b.sysroot) |sysroot| &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC++", "-std=c++17", "-stdlib=libc++", "-mmacosx-version-min=11.0", "-isysroot", sysroot, sdk_include, include_arg, define_arg } else &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC++", "-std=c++17", "-stdlib=libc++", "-mmacosx-version-min=11.0", include_arg, define_arg };
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/macos/cef_host.mm"), .flags = flags });
                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.a", .{cef_dir})));
                app_mod.addFrameworkPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
                app_mod.linkFramework("Chromium Embedded Framework", .{});
                app_mod.addRPath(.{ .cwd_relative = "@executable_path/Frameworks" });
            },
        }
        if (b.sysroot) |sysroot| {
            app_mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
        }
        app_mod.linkFramework("AppKit", .{});
        // The audio playback service (the AppKit host's single AVPlayer).
        app_mod.linkFramework("AVFoundation", .{});
        // Spectrum analysis of the app's own playback: the MediaToolbox
        // audio tap hands the player's PCM to the host, and Accelerate
        // (vDSP) turns it into band magnitudes.
        app_mod.linkFramework("MediaToolbox", .{});
        app_mod.linkFramework("Accelerate", .{});
        app_mod.linkFramework("Foundation", .{});
        app_mod.linkFramework("CoreText", .{});
        app_mod.linkFramework("UniformTypeIdentifiers", .{});
        app_mod.linkFramework("Security", .{});
        app_mod.linkFramework("Metal", .{});
        app_mod.linkFramework("QuartzCore", .{});
        app_mod.linkSystemLibrary("c", .{});
        if (web_engine == .chromium) app_mod.linkSystemLibrary("c++", .{});
    } else if (platform == .linux) {
        switch (web_engine) {
            .system => {
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/linux/gtk_host.c"), .flags = &.{} });
                app_mod.linkSystemLibrary("gtk4", .{});
                app_mod.linkSystemLibrary("webkitgtk-6.0", .{});
                app_mod.linkSystemLibrary("dl", .{});
            },
            .chromium => {
                const cef_check = addCefCheck(b, target, cef_dir);
                if (cef_auto_install) {
                    const cef_auto = b.addSystemCommand(&.{ "native", "cef", "install", "--dir", cef_dir });
                    cef_check.step.dependOn(&cef_auto.step);
                }
                exe.step.dependOn(&cef_check.step);
                const include_arg = b.fmt("-I{s}", .{cef_dir});
                const define_arg = b.fmt("-DNATIVE_SDK_CEF_DIR=\"{s}\"", .{cef_dir});
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/linux/cef_host.cpp"), .flags = &.{ "-std=c++17", include_arg, define_arg } });
                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.a", .{cef_dir})));
                app_mod.addLibraryPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
                app_mod.linkSystemLibrary("cef", .{});
                app_mod.addRPath(.{ .cwd_relative = "$ORIGIN" });
            },
        }
        app_mod.linkSystemLibrary("c", .{});
        if (web_engine == .chromium) app_mod.linkSystemLibrary("stdc++", .{});
    } else if (platform == .windows) {
        // Common-controls v6 side-by-side dependency: without this
        // manifest the loader binds the system-default v5 assembly, which
        // renders classic-styled controls and lacks the v6-only exports.
        exe.win32_manifest = dep.path("assets/native-sdk.manifest");
        switch (web_engine) {
            .system => app_mod.addCSourceFile(.{ .file = dep.path("src/platform/windows/webview2_host.cpp"), .flags = &.{"-std=c++17"} }),
            .chromium => {
                const cef_check = addCefCheck(b, target, cef_dir);
                if (cef_auto_install) {
                    const cef_auto = b.addSystemCommand(&.{ "native", "cef", "install", "--dir", cef_dir });
                    cef_check.step.dependOn(&cef_auto.step);
                }
                exe.step.dependOn(&cef_check.step);
                const include_arg = b.fmt("-I{s}", .{cef_dir});
                const define_arg = b.fmt("-DNATIVE_SDK_CEF_DIR=\"{s}\"", .{cef_dir});
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/windows/cef_host.cpp"), .flags = &.{ "-std=c++17", include_arg, define_arg } });
                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.lib", .{cef_dir})));
                app_mod.addLibraryPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
            },
        }
        app_mod.linkSystemLibrary("c", .{});
        app_mod.linkSystemLibrary("c++", .{});
        app_mod.linkSystemLibrary("user32", .{});
        app_mod.linkSystemLibrary("gdi32", .{});
        app_mod.linkSystemLibrary("imm32", .{});
        app_mod.linkSystemLibrary("comctl32", .{});
        app_mod.linkSystemLibrary("ole32", .{});
        app_mod.linkSystemLibrary("oleacc", .{});
        app_mod.linkSystemLibrary("shell32", .{});
        // The audio backend: Media Foundation (session + source resolver
        // + streaming audio renderer) and WinHTTP (the cache fill).
        app_mod.linkSystemLibrary("mf", .{});
        app_mod.linkSystemLibrary("mfplat", .{});
        app_mod.linkSystemLibrary("winhttp", .{});
        if (web_engine == .chromium) app_mod.linkSystemLibrary("libcef", .{});
    }
}

fn addCefRuntimeRunFiles(b: *std.Build, target: std.Build.ResolvedTarget, run: *std.Build.Step.Run, exe: *std.Build.Step.Compile, web_engine: WebEngineOption, cef_dir: []const u8) void {
    if (web_engine != .chromium) return;
    if (target.result.os.tag != .macos) return;
    const copy = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\set -e
            \\exe="$0"
            \\exe_dir="$(dirname "$exe")"
            \\rm -rf "zig-out/Frameworks/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/Chromium Embedded Framework.framework" &&
            \\mkdir -p "zig-out/Frameworks" "zig-out/bin/Frameworks" ".zig-cache/o/Frameworks" "$exe_dir" &&
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/Frameworks/" &&
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/" &&
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/" &&
            \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libEGL.dylib" "$exe_dir/" &&
            \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libGLESv2.dylib" "$exe_dir/" &&
            \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libvk_swiftshader.dylib" "$exe_dir/" &&
            \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/vk_swiftshader_icd.json" "$exe_dir/"
        , .{ cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir }),
    });
    copy.addFileArg(exe.getEmittedBin());
    run.step.dependOn(&copy.step);
}

fn addCefCheck(b: *std.Build, target: std.Build.ResolvedTarget, cef_dir: []const u8) *std.Build.Step.Run {
    const script = switch (target.result.os.tag) {
        .macos => b.fmt(
            \\test -f "{s}/include/cef_app.h" &&
            \\test -d "{s}/Release/Chromium Embedded Framework.framework" &&
            \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.a" || {{
            \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
            \\  echo "Fix with: native cef install --dir {s}" >&2
            \\  exit 1
            \\}}
        , .{ cef_dir, cef_dir, cef_dir, cef_dir }),
        .linux => b.fmt(
            \\test -f "{s}/include/cef_app.h" &&
            \\test -f "{s}/Release/libcef.so" &&
            \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.a" || {{
            \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
            \\  echo "Fix with: native cef install --dir {s}" >&2
            \\  exit 1
            \\}}
        , .{ cef_dir, cef_dir, cef_dir, cef_dir }),
        .windows => b.fmt(
            \\test -f "{s}/include/cef_app.h" &&
            \\test -f "{s}/Release/libcef.dll" &&
            \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.lib" || {{
            \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
            \\  echo "Fix with: native cef install --dir {s}" >&2
            \\  exit 1
            \\}}
        , .{ cef_dir, cef_dir, cef_dir, cef_dir }),
        else => "echo unsupported CEF target >&2; exit 1",
    };
    return b.addSystemCommand(&.{ "sh", "-c", script });
}

const AppWebEngineConfig = struct {
    web_engine: WebEngineOption = .system,
    cef_dir: []const u8 = "third_party/cef/macos",
    cef_auto_install: bool = false,
};

fn defaultCefDir(platform: PlatformOption, configured: []const u8) []const u8 {
    if (!std.mem.eql(u8, configured, "third_party/cef/macos")) return configured;
    return switch (platform) {
        .linux => "third_party/cef/linux",
        .windows => "third_party/cef/windows",
        else => configured,
    };
}

/// Resolve an app-relative path against `app_root` (see AppOptions). Kept
/// lexical: `b.path` rejects absolute paths and the generated build graph
/// hands us "../..", which openat/b.path both resolve fine.
fn appPath(b: *std.Build, app_root: []const u8, sub_path: []const u8) []const u8 {
    if (app_root.len == 0 or std.mem.eql(u8, app_root, ".")) return sub_path;
    return b.pathJoin(&.{ app_root, sub_path });
}

fn appWebEngineConfig(b: *std.Build, app_root: []const u8) AppWebEngineConfig {
    const source = b.build_root.handle.readFileAlloc(b.graph.io, appPath(b, app_root, "app.zon"), b.allocator, .limited(1024 * 1024)) catch return .{};
    var config: AppWebEngineConfig = .{};
    if (stringField(source, ".web_engine")) |value| {
        config.web_engine = parseWebEngine(value) orelse .system;
    }
    if (objectSection(source, ".cef")) |cef| {
        if (stringField(cef, ".dir")) |value| config.cef_dir = value;
        if (boolField(cef, ".auto_install")) |value| config.cef_auto_install = value;
    }
    return config;
}

fn parseWebEngine(value: []const u8) ?WebEngineOption {
    if (std.mem.eql(u8, value, "system")) return .system;
    if (std.mem.eql(u8, value, "chromium")) return .chromium;
    return null;
}

fn stringField(source: []const u8, field: []const u8) ?[]const u8 {
    const field_index = std.mem.indexOf(u8, source, field) orelse return null;
    const equals = std.mem.indexOfScalarPos(u8, source, field_index, '=') orelse return null;
    const start_quote = std.mem.indexOfScalarPos(u8, source, equals, '"') orelse return null;
    const end_quote = std.mem.indexOfScalarPos(u8, source, start_quote + 1, '"') orelse return null;
    return source[start_quote + 1 .. end_quote];
}

fn objectSection(source: []const u8, field: []const u8) ?[]const u8 {
    const field_index = std.mem.indexOf(u8, source, field) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, source, field_index, '{') orelse return null;
    var depth: usize = 0;
    var index = open;
    while (index < source.len) : (index += 1) {
        switch (source[index]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return source[open + 1 .. index];
            },
            else => {},
        }
    }
    return null;
}

fn boolField(source: []const u8, field: []const u8) ?bool {
    const field_index = std.mem.indexOf(u8, source, field) orelse return null;
    const equals = std.mem.indexOfScalarPos(u8, source, field_index, '=') orelse return null;
    var index = equals + 1;
    while (index < source.len and std.ascii.isWhitespace(source[index])) : (index += 1) {}
    if (std.mem.startsWith(u8, source[index..], "true")) return true;
    if (std.mem.startsWith(u8, source[index..], "false")) return false;
    return null;
}
