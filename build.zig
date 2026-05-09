const std = @import("std");
const web_engine_tool = @import("src/tooling/web_engine.zig");

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

const PackageTarget = enum {
    macos,
    windows,
    linux,
    ios,
    android,
};

const SigningMode = enum {
    none,
    adhoc,
    identity,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform_option = b.option(PlatformOption, "platform", "Desktop backend: auto, null, macos, linux, windows") orelse .auto;
    const trace_option = b.option(TraceOption, "trace", "Trace output: off, events, runtime, all") orelse .events;
    _ = b.option(bool, "debug-overlay", "Enable debug overlay output") orelse false;
    _ = b.option(bool, "automation", "Enable zero-native automation artifacts") orelse false;
    _ = b.option(bool, "webview", "Deprecated: WebView is the only runtime surface") orelse true;
    const web_engine_override = b.option(WebEngineOption, "web-engine", "Override app.zon web engine: system, chromium");
    const cef_dir_override = b.option([]const u8, "cef-dir", "Override CEF root directory for Chromium builds");
    const cef_auto_install_override = b.option(bool, "cef-auto-install", "Override app.zon CEF auto-install setting");
    _ = b.option(bool, "js-bridge", "Enable optional JavaScript bridge stubs") orelse false;
    const package_target = b.option(PackageTarget, "package-target", "Package target: macos, windows, linux, ios, android") orelse .macos;
    const signing_mode = b.option(SigningMode, "signing", "Signing mode: none, adhoc, identity") orelse .none;
    const package_version = packageVersion(b);
    const optimize_name = @tagName(optimize);
    const app_web_engine = web_engine_tool.readManifestConfig(b.allocator, b.graph.io, "app.zon") catch |err| {
        std.debug.panic("failed to read app.zon web engine config: {s}", .{@errorName(err)});
    };
    const resolved_web_engine = web_engine_tool.resolve(app_web_engine, .{
        .web_engine = if (web_engine_override) |value| webEngineFromBuildOption(value) else null,
        .cef_dir = cef_dir_override,
        .cef_auto_install = cef_auto_install_override,
    }) catch |err| {
        std.debug.panic("invalid app.zon web engine config: {s}", .{@errorName(err)});
    };
    const web_engine = buildWebEngineFromResolved(resolved_web_engine.engine);
    const cef_auto_install = resolved_web_engine.cef_auto_install;
    const selected_platform: PlatformOption = switch (platform_option) {
        .auto => if (target.result.os.tag == .macos) .macos else if (target.result.os.tag == .linux) .linux else if (target.result.os.tag == .windows) .windows else .null,
        else => platform_option,
    };
    const cef_dir = cef_dir_override orelse defaultCefDir(selected_platform, resolved_web_engine.cef_dir);
    if (selected_platform == .macos and target.result.os.tag != .macos) {
        @panic("-Dplatform=macos requires a macOS target");
    }
    if (selected_platform == .linux and target.result.os.tag != .linux) {
        @panic("-Dplatform=linux requires a Linux target");
    }
    if (selected_platform == .windows and target.result.os.tag != .windows) {
        @panic("-Dplatform=windows requires a Windows target");
    }
    if (web_engine == .chromium and selected_platform == .null) {
        @panic("-Dweb-engine=chromium requires -Dplatform=macos, linux, or windows");
    }

    const geometry_mod = module(b, target, optimize, "src/primitives/geometry/root.zig");
    const assets_mod = module(b, target, optimize, "src/primitives/assets/root.zig");
    const app_dirs_mod = module(b, target, optimize, "src/primitives/app_dirs/root.zig");
    const trace_mod = module(b, target, optimize, "src/primitives/trace/root.zig");
    const app_manifest_mod = module(b, target, optimize, "src/primitives/app_manifest/root.zig");
    const diagnostics_mod = module(b, target, optimize, "src/primitives/diagnostics/root.zig");
    const platform_info_mod = module(b, target, optimize, "src/primitives/platform_info/root.zig");
    const json_mod = module(b, target, optimize, "src/primitives/json/root.zig");
    const debug_mod = module(b, target, optimize, "src/debug/root.zig");
    debug_mod.addImport("app_dirs", app_dirs_mod);
    debug_mod.addImport("trace", trace_mod);

    const geometry_tests = testArtifact(b, geometry_mod);
    const assets_tests = testArtifact(b, assets_mod);
    const app_dirs_tests = testArtifact(b, app_dirs_mod);
    const trace_tests = testArtifact(b, trace_mod);
    const app_manifest_tests = testArtifact(b, app_manifest_mod);
    const diagnostics_tests = testArtifact(b, diagnostics_mod);
    const platform_info_tests = testArtifact(b, platform_info_mod);
    const json_tests = testArtifact(b, json_mod);

    const desktop_mod = module(b, target, optimize, "src/root.zig");
    desktop_mod.addImport("geometry", geometry_mod);
    desktop_mod.addImport("app_dirs", app_dirs_mod);
    desktop_mod.addImport("assets", assets_mod);
    desktop_mod.addImport("trace", trace_mod);
    desktop_mod.addImport("app_manifest", app_manifest_mod);
    desktop_mod.addImport("diagnostics", diagnostics_mod);
    desktop_mod.addImport("platform_info", platform_info_mod);
    desktop_mod.addImport("json", json_mod);
    desktop_mod.export_symbol_names = &.{
        "zero_native_app_create",
        "zero_native_app_destroy",
        "zero_native_app_start",
        "zero_native_app_stop",
        "zero_native_app_resize",
        "zero_native_app_touch",
        "zero_native_app_frame",
        "zero_native_app_set_asset_root",
        "zero_native_app_last_command_count",
        "zero_native_app_last_error_name",
    };
    const desktop_tests = testArtifact(b, desktop_mod);

    const embed_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zero-native",
        .root_module = desktop_mod,
    });
    b.installArtifact(embed_lib);

    const automation_protocol_mod = module(b, target, optimize, "src/automation/protocol.zig");
    const tooling_mod = module(b, target, optimize, "src/tooling/root.zig");
    tooling_mod.addImport("assets", assets_mod);
    tooling_mod.addImport("app_dirs", app_dirs_mod);
    tooling_mod.addImport("app_manifest", app_manifest_mod);
    tooling_mod.addImport("diagnostics", diagnostics_mod);
    tooling_mod.addImport("debug", debug_mod);
    tooling_mod.addImport("platform_info", platform_info_mod);
    tooling_mod.addImport("trace", trace_mod);
    const tooling_tests = testArtifact(b, tooling_mod);

    const cli_mod = module(b, target, optimize, "tools/zero-native/main.zig");
    cli_mod.addImport("tooling", tooling_mod);
    cli_mod.addImport("automation_protocol", automation_protocol_mod);
    const cli_tests = testArtifact(b, cli_mod);
    const cli_exe = b.addExecutable(.{
        .name = "zero-native",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    const platform_arg = switch (selected_platform) {
        .auto => unreachable,
        .null => "null",
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
    };

    const test_step = b.step("test", "Run package and framework tests");
    test_step.dependOn(&b.addRunArtifact(geometry_tests).step);
    test_step.dependOn(&b.addRunArtifact(assets_tests).step);
    test_step.dependOn(&b.addRunArtifact(app_dirs_tests).step);
    test_step.dependOn(&b.addRunArtifact(trace_tests).step);
    test_step.dependOn(&b.addRunArtifact(app_manifest_tests).step);
    test_step.dependOn(&b.addRunArtifact(diagnostics_tests).step);
    test_step.dependOn(&b.addRunArtifact(platform_info_tests).step);
    test_step.dependOn(&b.addRunArtifact(json_tests).step);
    test_step.dependOn(&b.addRunArtifact(desktop_tests).step);
    test_step.dependOn(&b.addRunArtifact(tooling_tests).step);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    addTestStep(b, "test-geometry", "Run geometry module tests", geometry_tests);
    addTestStep(b, "test-assets", "Run assets module tests", assets_tests);
    addTestStep(b, "test-app-dirs", "Run app directory module tests", app_dirs_tests);
    addTestStep(b, "test-trace", "Run trace module tests", trace_tests);
    addTestStep(b, "test-app-manifest", "Run app manifest module tests", app_manifest_tests);
    addTestStep(b, "test-diagnostics", "Run diagnostics module tests", diagnostics_tests);
    addTestStep(b, "test-platform-info", "Run platform info module tests", platform_info_tests);
    addTestStep(b, "test-json", "Run JSON primitive tests", json_tests);
    addTestStep(b, "test-desktop", "Run zero-native framework tests", desktop_tests);
    addTestStep(b, "test-tooling", "Run zero-native tooling tests", tooling_tests);
    addTestStep(b, "test-cli", "Run zero-native CLI tests", cli_tests);

    const run_hello = b.addSystemCommand(&.{ "zig", "build", "run", b.fmt("-Dplatform={s}", .{platform_arg}), b.fmt("-Dtrace={s}", .{@tagName(trace_option)}) });
    run_hello.setCwd(b.path("examples/hello"));
    const run_hello_step = b.step("run-hello", "Run the zero-native hello WebView example");
    run_hello_step.dependOn(&run_hello.step);

    const run_webview = b.addSystemCommand(&.{ "zig", "build", "run", b.fmt("-Dplatform={s}", .{platform_arg}), b.fmt("-Dtrace={s}", .{@tagName(trace_option)}), b.fmt("-Dweb-engine={s}", .{@tagName(web_engine)}), b.fmt("-Dcef-dir={s}", .{cef_dir}) });
    run_webview.setCwd(b.path("examples/webview"));
    const run_webview_step = b.step("run-webview", "Run the zero-native WebView example");
    run_webview_step.dependOn(&run_webview.step);

    const build_webview_system = b.addSystemCommand(&.{ "zig", "build", b.fmt("-Dplatform={s}", .{platform_arg}), "-Dweb-engine=system" });
    build_webview_system.setCwd(b.path("examples/webview"));
    const webview_system_link_step = b.step("test-webview-system-link", "Build the WebView example with the system engine");
    webview_system_link_step.dependOn(&build_webview_system.step);

    const frontend_examples_step = b.step("test-examples-frontends", "Run frontend example tests");
    addExampleTestStep(b, frontend_examples_step, "test-example-next", "Run Next example tests", "examples/next");
    addExampleTestStep(b, frontend_examples_step, "test-example-react", "Run React example tests", "examples/react");
    addExampleTestStep(b, frontend_examples_step, "test-example-svelte", "Run Svelte example tests", "examples/svelte");
    addExampleTestStep(b, frontend_examples_step, "test-example-vue", "Run Vue example tests", "examples/vue");

    const mobile_examples_step = b.step("test-examples-mobile", "Verify mobile example project layouts");
    addLayoutCheckStep(b, mobile_examples_step, "test-example-ios-layout", "Verify iOS example layout", &.{
        "examples/ios/README.md",
        "examples/ios/app.zon",
        "examples/ios/ZeroNativeIOSExample.xcodeproj/project.pbxproj",
        "examples/ios/ZeroNativeIOSExample/AppDelegate.swift",
        "examples/ios/ZeroNativeIOSExample/SceneDelegate.swift",
        "examples/ios/ZeroNativeIOSExample/ZeroNativeHostViewController.swift",
        "examples/ios/ZeroNativeIOSExample/zero_native.h",
    });
    addLayoutCheckStep(b, mobile_examples_step, "test-example-android-layout", "Verify Android example layout", &.{
        "examples/android/README.md",
        "examples/android/app.zon",
        "examples/android/settings.gradle",
        "examples/android/build.gradle",
        "examples/android/app/build.gradle",
        "examples/android/app/src/main/AndroidManifest.xml",
        "examples/android/app/src/main/java/dev/zero_native/examples/android/MainActivity.kt",
        "examples/android/app/src/main/cpp/CMakeLists.txt",
        "examples/android/app/src/main/cpp/zero_native_jni.c",
        "examples/android/app/src/main/cpp/zero_native.h",
    });

    const build_webview_cef = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=macos", "-Dweb-engine=chromium", b.fmt("-Dcef-dir={s}", .{cef_dir}) });
    build_webview_cef.setCwd(b.path("examples/webview"));
    const webview_cef_link_step = b.step("test-webview-cef-link", "Build the WebView example with Chromium/CEF");
    webview_cef_link_step.dependOn(&build_webview_cef.step);

    const webview_smoke_step = b.step("test-webview-smoke", "Run macOS WebView automation smoke test");
    const webview_smoke_build = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true", "-Djs-bridge=true" });
    webview_smoke_build.setCwd(b.path("examples/webview"));
    const webview_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/webview
        \\app="zig-out/bin/webview"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\request='{"id":"smoke","command":"native.ping","payload":{"source":"smoke"}}'
        \\response_file=".zig-cache/zero-native-automation/bridge-response.txt"
        \\mkdir -p .zig-cache/zero-native-automation
        \\rm -f .zig-cache/zero-native-automation/snapshot.txt .zig-cache/zero-native-automation/windows.txt .zig-cache/zero-native-automation/command.txt "$response_file"
        \\printf 'bridge %s\n' "$request" > .zig-cache/zero-native-automation/command.txt
        \\"$app" > .zig-cache/zero-native-webview-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true' EXIT
        \\snapshot="$("$cli" automate wait 2>&1)"
        \\case "$snapshot" in *"ready=true"*) ;; *) echo "automation snapshot was not ready" >&2; exit 1 ;; esac
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "native.ping did not succeed: $response" >&2; exit 1 ;; esac
        \\case "$response" in *'pong from Zig'*) ;; *) echo "native.ping response was unexpected: $response" >&2; exit 1 ;; esac
        \\echo "webview smoke ok"
        ,
        "sh",
    });
    webview_smoke_run.addFileArg(cli_exe.getEmittedBin());
    webview_smoke_run.step.dependOn(&webview_smoke_build.step);
    webview_smoke_run.step.dependOn(&cli_exe.step);
    webview_smoke_step.dependOn(&webview_smoke_run.step);

    const webview_cef_smoke_step = b.step("test-webview-cef-smoke", "Run macOS Chromium WebView automation smoke test");
    const webview_cef_smoke_build = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=macos", "-Dweb-engine=chromium", b.fmt("-Dcef-dir={s}", .{cef_dir}), "-Dautomation=true", "-Djs-bridge=true" });
    webview_cef_smoke_build.setCwd(b.path("examples/webview"));
    const webview_cef_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/webview
        \\app="zig-out/bin/webview"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\request='{"id":"ping","command":"native.ping","payload":{"source":"cef-smoke"}}'
        \\response_file=".zig-cache/zero-native-automation/bridge-response.txt"
        \\mkdir -p .zig-cache/zero-native-automation
        \\rm -f .zig-cache/zero-native-automation/snapshot.txt .zig-cache/zero-native-automation/windows.txt .zig-cache/zero-native-automation/command.txt "$response_file"
        \\printf 'bridge %s\n' "$request" > .zig-cache/zero-native-automation/command.txt
        \\"$app" > .zig-cache/zero-native-webview-cef-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true' EXIT
        \\snapshot="$("$cli" automate wait 2>&1)"
        \\case "$snapshot" in *"ready=true"*) ;; *) echo "automation snapshot was not ready" >&2; exit 1 ;; esac
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*'pong from Zig'*) ;; *) echo "native.ping response was unexpected: $response" >&2; exit 1 ;; esac
        \\echo "cef webview smoke ok"
        ,
        "sh",
    });
    webview_cef_smoke_run.addFileArg(cli_exe.getEmittedBin());
    webview_cef_smoke_run.step.dependOn(&webview_cef_smoke_build.step);
    webview_cef_smoke_run.step.dependOn(&cli_exe.step);
    webview_cef_smoke_step.dependOn(&webview_cef_smoke_run.step);

    const dev_run = b.addSystemCommand(&.{ "zig", "build", "run", b.fmt("-Dplatform={s}", .{platform_arg}) });
    dev_run.setCwd(b.path("examples/webview"));
    const dev_step = b.step("dev", "Run managed frontend dev server and native shell");
    dev_step.dependOn(&dev_run.step);

    const lib_step = b.step("lib", "Build zero-native embeddable static library");
    lib_step.dependOn(&b.addInstallArtifact(embed_lib, .{}).step);

    const doctor_run = b.addRunArtifact(cli_exe);
    doctor_run.addArg("doctor");
    const doctor_step = b.step("doctor", "Print zero-native platform diagnostics");
    doctor_step.dependOn(&doctor_run.step);

    const validate_run = b.addRunArtifact(cli_exe);
    validate_run.addArgs(&.{ "validate", "app.zon" });
    const validate_step = b.step("validate", "Validate app.zon");
    validate_step.dependOn(&validate_run.step);

    const bundle_run = b.addRunArtifact(cli_exe);
    bundle_run.addArgs(&.{ "bundle-assets", "app.zon", "assets", "zig-out/assets" });
    const bundle_step = b.step("bundle-assets", "Bundle app assets");
    bundle_step.dependOn(&bundle_run.step);

    const package_run = b.addRunArtifact(cli_exe);
    package_run.addArgs(&.{
        "package",
        "--target",
        @tagName(package_target),
        "--output",
        b.fmt("zig-out/package/zero-native-{s}-{s}-{s}{s}", .{ package_version, @tagName(package_target), optimize_name, packageSuffix(package_target) }),
        "--binary",
    });
    package_run.addFileArg(embed_lib.getEmittedBin());
    package_run.addArgs(&.{ "--manifest", "app.zon", "--assets", "assets", "--optimize", optimize_name, "--signing", @tagName(signing_mode), "--web-engine", @tagName(web_engine), "--cef-dir", cef_dir });
    if (cef_auto_install) package_run.addArg("--cef-auto-install");
    package_run.step.dependOn(&embed_lib.step);
    package_run.step.dependOn(&bundle_run.step);
    const package_step = b.step("package", "Create local package artifact");
    package_step.dependOn(&package_run.step);

    const package_cef_run = b.addRunArtifact(cli_exe);
    package_cef_run.addArgs(&.{
        "package",
        "--target",
        "macos",
        "--output",
        b.fmt("zig-out/package/zero-native-cef-smoke-{s}.app", .{optimize_name}),
        "--binary",
    });
    package_cef_run.addFileArg(embed_lib.getEmittedBin());
    package_cef_run.addArgs(&.{ "--manifest", "app.zon", "--assets", "assets", "--optimize", optimize_name, "--web-engine", "chromium", "--cef-dir", cef_dir });
    if (cef_auto_install) package_cef_run.addArg("--cef-auto-install");
    package_cef_run.step.dependOn(&embed_lib.step);
    package_cef_run.step.dependOn(&bundle_run.step);

    const package_cef_check = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\set -e
            \\app="zig-out/package/zero-native-cef-smoke-{s}.app"
            \\test -d "$app/Contents/Frameworks/Chromium Embedded Framework.framework"
            \\test -f "$app/Contents/Frameworks/Chromium Embedded Framework.framework/Resources/icudtl.dat"
            \\test -f "$app/Contents/Frameworks/Chromium Embedded Framework.framework/Libraries/libGLESv2.dylib"
            \\test -f "$app/Contents/Resources/package-manifest.zon"
            \\echo "cef package layout ok"
        , .{optimize_name}),
    });
    package_cef_check.step.dependOn(&package_cef_run.step);
    const package_cef_smoke_step = b.step("test-package-cef-layout", "Verify macOS Chromium package layout");
    package_cef_smoke_step.dependOn(&package_cef_check.step);

    const package_windows_run = b.addRunArtifact(cli_exe);
    package_windows_run.addArgs(&.{ "package-windows", "--output", b.fmt("zig-out/package/zero-native-{s}-windows-Debug", .{package_version}), "--manifest", "app.zon", "--assets", "assets" });
    const package_windows_step = b.step("package-windows", "Create local Windows artifact directory");
    package_windows_step.dependOn(&package_windows_run.step);

    const package_linux_run = b.addRunArtifact(cli_exe);
    package_linux_run.addArgs(&.{ "package-linux", "--output", b.fmt("zig-out/package/zero-native-{s}-linux-Debug", .{package_version}), "--manifest", "app.zon", "--assets", "assets" });
    const package_linux_step = b.step("package-linux", "Create local Linux artifact directory");
    package_linux_step.dependOn(&package_linux_run.step);

    const package_ios_run = b.addRunArtifact(cli_exe);
    package_ios_run.addArgs(&.{ "package-ios", "--output", b.fmt("zig-out/mobile/zero-native-{s}-ios-Debug", .{package_version}), "--manifest", "app.zon", "--assets", "assets", "--binary" });
    package_ios_run.addFileArg(embed_lib.getEmittedBin());
    package_ios_run.step.dependOn(&embed_lib.step);
    const package_ios_step = b.step("package-ios", "Create local iOS host skeleton");
    package_ios_step.dependOn(&package_ios_run.step);

    const package_android_run = b.addRunArtifact(cli_exe);
    package_android_run.addArgs(&.{ "package-android", "--output", b.fmt("zig-out/mobile/zero-native-{s}-android-Debug", .{package_version}), "--manifest", "app.zon", "--assets", "assets", "--binary" });
    package_android_run.addFileArg(embed_lib.getEmittedBin());
    package_android_run.step.dependOn(&embed_lib.step);
    const package_android_step = b.step("package-android", "Create local Android host skeleton");
    package_android_step.dependOn(&package_android_run.step);

    const generate_icon_step = b.step("generate-icon", "Generate .icns and .ico from assets/icon.png");
    const iconset_script = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\command -v python3 >/dev/null || { echo "python3 required for icon generation" >&2; exit 1; }
        \\python3 -c "
        \\from PIL import Image; import os
        \\img = Image.open('assets/icon.png')
        \\iconset = 'zig-out/icon.iconset'
        \\os.makedirs(iconset, exist_ok=True)
        \\for name, sz in {'icon_16x16.png':16,'icon_16x16@2x.png':32,'icon_32x32.png':32,'icon_32x32@2x.png':64,'icon_128x128.png':128,'icon_128x128@2x.png':256,'icon_256x256.png':256,'icon_256x256@2x.png':512,'icon_512x512.png':512,'icon_512x512@2x.png':1024}.items():
        \\    img.resize((sz,sz),Image.LANCZOS).save(os.path.join(iconset,name),'PNG')
        \\img.save('assets/icon.ico',format='ICO',sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])
        \\"
        \\iconutil -c icns zig-out/icon.iconset -o assets/icon.icns
        \\echo "generated assets/icon.icns and assets/icon.ico"
    });
    generate_icon_step.dependOn(&iconset_script.step);

    const notarize_run = b.addRunArtifact(cli_exe);
    notarize_run.addArgs(&.{
        "package",
        "--target",
        "macos",
        "--output",
        b.fmt("zig-out/package/zero-native-{s}-macos-{s}.app", .{ package_version, optimize_name }),
        "--binary",
    });
    notarize_run.addFileArg(embed_lib.getEmittedBin());
    notarize_run.addArgs(&.{ "--manifest", "app.zon", "--assets", "assets", "--optimize", optimize_name, "--signing", "identity", "--web-engine", @tagName(web_engine), "--cef-dir", cef_dir });
    if (cef_auto_install) notarize_run.addArg("--cef-auto-install");
    notarize_run.step.dependOn(&embed_lib.step);
    notarize_run.step.dependOn(&bundle_run.step);
    const notarize_step = b.step("notarize", "Package, sign with identity, and notarize for macOS distribution");
    notarize_step.dependOn(&notarize_run.step);

    const dmg_script = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\APP="zig-out/package/zero-native-{s}-macos-{s}.app"
            \\DMG="zig-out/package/zero-native-{s}-macos-{s}.dmg"
            \\test -d "$APP" || {{ echo "run 'zig build package' first" >&2; exit 1; }}
            \\hdiutil create -volname "zero-native" -srcfolder "$APP" -ov -format UDZO "$DMG"
            \\echo "created $DMG"
        , .{ package_version, optimize_name, package_version, optimize_name }),
    });
    dmg_script.step.dependOn(&package_run.step);
    const dmg_step = b.step("dmg", "Create macOS .dmg disk image from the packaged .app");
    dmg_step.dependOn(&dmg_script.step);

    const cef_bundle_script = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\set -e
            \\rm -rf "zig-out/Frameworks/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/Chromium Embedded Framework.framework"
            \\mkdir -p "zig-out/Frameworks" "zig-out/bin/Frameworks" ".zig-cache/o/Frameworks"
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/Frameworks/"
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/"
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/"
            \\if [ -d "{s}/Resources" ]; then
            \\  mkdir -p "zig-out/bin/Resources/cef"
            \\  cp -R "{s}/Resources/"* "zig-out/bin/Resources/cef/"
            \\fi
            \\echo "CEF framework copied for local dev runs"
        , .{ cef_dir, cef_dir, cef_dir, cef_dir, cef_dir }),
    });
    const cef_bundle_step = b.step("cef-bundle", "Copy CEF framework and resources into zig-out/bin/ for local dev runs");
    if (cef_auto_install) {
        const cef_bundle_auto = b.addRunArtifact(cli_exe);
        cef_bundle_auto.addArgs(&.{ "cef", "install", "--dir", cef_dir });
        cef_bundle_script.step.dependOn(&cef_bundle_auto.step);
    }
    cef_bundle_step.dependOn(&cef_bundle_script.step);
}

fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
}

fn testArtifact(b: *std.Build, mod: *std.Build.Module) *std.Build.Step.Compile {
    return b.addTest(.{ .root_module = mod });
}

fn addTestStep(b: *std.Build, name: []const u8, description: []const u8, artifact: *std.Build.Step.Compile) void {
    const step = b.step(name, description);
    step.dependOn(&b.addRunArtifact(artifact).step);
}

fn addExampleTestStep(b: *std.Build, group: *std.Build.Step, name: []const u8, description: []const u8, example_path: []const u8) void {
    const run = b.addSystemCommand(&.{ "zig", "build", "test", "-Dplatform=null" });
    run.setCwd(b.path(example_path));
    const step = b.step(name, description);
    step.dependOn(&run.step);
    group.dependOn(&run.step);
}

fn addLayoutCheckStep(b: *std.Build, group: *std.Build.Step, name: []const u8, description: []const u8, paths: []const []const u8) void {
    const step = b.step(name, description);
    for (paths) |path| {
        const check = b.addSystemCommand(&.{ "test", "-f", path });
        step.dependOn(&check.step);
        group.dependOn(&check.step);
    }
}

fn packageSuffix(target: PackageTarget) []const u8 {
    return switch (target) {
        .macos => ".app",
        .windows, .linux, .ios, .android => "",
    };
}

fn packageVersion(b: *std.Build) []const u8 {
    var file = std.Io.Dir.cwd().openFile(b.graph.io, "build.zig.zon", .{}) catch return "0.1.0";
    defer file.close(b.graph.io);
    var buffer: [4096]u8 = undefined;
    const len = file.readPositionalAll(b.graph.io, &buffer, 0) catch return "0.1.0";
    const bytes = buffer[0..len];
    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, bytes, marker) orelse return "0.1.0";
    const value_start = start + marker.len;
    const value_end = std.mem.indexOfScalarPos(u8, bytes, value_start, '"') orelse return "0.1.0";
    return b.allocator.dupe(u8, bytes[value_start..value_end]) catch return "0.1.0";
}

fn defaultCefDir(platform: PlatformOption, configured: []const u8) []const u8 {
    if (!std.mem.eql(u8, configured, web_engine_tool.default_cef_dir)) return configured;
    return switch (platform) {
        .linux => "third_party/cef/linux",
        .windows => "third_party/cef/windows",
        else => configured,
    };
}

fn webEngineFromBuildOption(option: WebEngineOption) web_engine_tool.Engine {
    return switch (option) {
        .system => .system,
        .chromium => .chromium,
    };
}

fn buildWebEngineFromResolved(engine: web_engine_tool.Engine) WebEngineOption {
    return switch (engine) {
        .system => .system,
        .chromium => .chromium,
    };
}
