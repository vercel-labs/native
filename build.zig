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

pub const AppOptions = @import("build/app.zig").AppOptions;
pub const addApp = @import("build/app.zig").addApp;
pub const AppArtifacts = @import("build/app.zig").AppArtifacts;
pub const addAppArtifacts = @import("build/app.zig").addAppArtifacts;
pub const MobileLibOptions = @import("build/app.zig").MobileLibOptions;
pub const addMobileLib = @import("build/app.zig").addMobileLib;
const mobile_export_symbol_names = @import("build/app.zig").mobile_export_symbol_names;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const host_target = b.graph.host;
    const optimize = b.standardOptimizeOption(.{});
    const platform_option = b.option(PlatformOption, "platform", "Desktop backend: auto, null, macos, linux, windows") orelse .auto;
    const trace_option = b.option(TraceOption, "trace", "Trace output: off, events, runtime, all") orelse .events;
    _ = b.option(bool, "debug-overlay", "Enable debug overlay output") orelse false;
    _ = b.option(bool, "automation", "Enable Native SDK automation artifacts") orelse false;
    _ = b.option(bool, "webview", "Deprecated compatibility flag; native surfaces are always enabled") orelse true;
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
    const browser_web_engine: WebEngineOption = web_engine_override orelse .system;
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
    if (web_engine == .chromium and selected_platform != .macos) {
        @panic("-Dweb-engine=chromium currently requires -Dplatform=macos");
    }

    const geometry_mod = module(b, target, optimize, "src/primitives/geometry/root.zig");
    const assets_mod = module(b, target, optimize, "src/primitives/assets/root.zig");
    const app_dirs_mod = module(b, target, optimize, "src/primitives/app_dirs/root.zig");
    const trace_mod = module(b, target, optimize, "src/primitives/trace/root.zig");
    const app_manifest_mod = module(b, target, optimize, "src/primitives/app_manifest/root.zig");
    const diagnostics_mod = module(b, target, optimize, "src/primitives/diagnostics/root.zig");
    const platform_info_mod = module(b, target, optimize, "src/primitives/platform_info/root.zig");
    const json_mod = module(b, target, optimize, "src/primitives/json/root.zig");
    const canvas_mod = module(b, target, optimize, "src/primitives/canvas/root.zig");
    canvas_mod.addImport("geometry", geometry_mod);
    canvas_mod.addImport("json", json_mod);
    if (target.result.os.tag == .macos) {
        // The estimator-vs-CoreText agreement test (text_metrics_tests.zig)
        // shapes the bundled face through CoreText; apps already link these
        // transitively via AppKit.
        canvas_mod.linkFramework("CoreFoundation", .{});
        canvas_mod.linkFramework("CoreGraphics", .{});
        canvas_mod.linkFramework("CoreText", .{});
        canvas_mod.linkSystemLibrary("c", .{});
    }
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
    const canvas_tests = testArtifact(b, canvas_mod);

    const desktop_mod = module(b, target, optimize, "src/root.zig");
    desktop_mod.addImport("geometry", geometry_mod);
    desktop_mod.addImport("app_dirs", app_dirs_mod);
    desktop_mod.addImport("assets", assets_mod);
    desktop_mod.addImport("trace", trace_mod);
    desktop_mod.addImport("app_manifest", app_manifest_mod);
    desktop_mod.addImport("diagnostics", diagnostics_mod);
    desktop_mod.addImport("platform_info", platform_info_mod);
    desktop_mod.addImport("json", json_mod);
    desktop_mod.addImport("canvas", canvas_mod);
    const desktop_tests = testArtifact(b, desktop_mod);

    // The embeddable static library's root module carries only the C ABI
    // exports (fixed WebView shell host); user-app canvas libraries are
    // produced by `addMobileLib` from src/embed/app_exports.zig instead.
    const embed_exports_mod = module(b, target, optimize, "src/embed/c_exports.zig");
    embed_exports_mod.addImport("native_sdk", desktop_mod);
    embed_exports_mod.export_symbol_names = &mobile_export_symbol_names;
    const embed_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "native-sdk",
        .root_module = embed_exports_mod,
    });
    b.installArtifact(embed_lib);

    const automation_protocol_mod = module(b, target, optimize, "src/automation/protocol.zig");
    const automation_protocol_tests = testArtifact(b, automation_protocol_mod);
    const tooling_mod = module(b, target, optimize, "src/tooling/root.zig");
    tooling_mod.addImport("assets", assets_mod);
    tooling_mod.addImport("app_dirs", app_dirs_mod);
    tooling_mod.addImport("app_manifest", app_manifest_mod);
    tooling_mod.addImport("diagnostics", diagnostics_mod);
    tooling_mod.addImport("debug", debug_mod);
    tooling_mod.addImport("platform_info", platform_info_mod);
    tooling_mod.addImport("trace", trace_mod);
    const tooling_tests = testArtifact(b, tooling_mod);

    const ui_markup_mod = module(b, target, optimize, "src/primitives/canvas/ui_markup.zig");
    const markup_lsp_mod = module(b, target, optimize, "tools/native-sdk/markup_lsp.zig");
    markup_lsp_mod.addImport("ui_markup", ui_markup_mod);
    const markup_lsp_tests = testArtifact(b, markup_lsp_mod);

    const automation_cli_mod = module(b, target, optimize, "tools/native-sdk/automation.zig");
    automation_cli_mod.addImport("automation_protocol", automation_protocol_mod);
    const automation_cli_tests = testArtifact(b, automation_cli_mod);

    // `native version` names the commit the binary was built from, so
    // binary/framework skew ("your native binary may be stale") is a
    // one-command check. Falls back to "unknown" outside a git checkout.
    const cli_build_info = b.addOptions();
    cli_build_info.addOption([]const u8, "build_commit", cliBuildCommit(b));

    const cli_mod = module(b, target, optimize, "tools/native-sdk/main.zig");
    cli_mod.addImport("tooling", tooling_mod);
    cli_mod.addImport("automation_protocol", automation_protocol_mod);
    cli_mod.addImport("ui_markup", ui_markup_mod);
    cli_mod.addImport("markup_lsp", markup_lsp_mod);
    cli_mod.addOptions("cli_build_info", cli_build_info);
    const cli_exe = b.addExecutable(.{
        .name = "native",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    const host_assets_mod = module(b, host_target, optimize, "src/primitives/assets/root.zig");
    const host_app_dirs_mod = module(b, host_target, optimize, "src/primitives/app_dirs/root.zig");
    const host_app_manifest_mod = module(b, host_target, optimize, "src/primitives/app_manifest/root.zig");
    const host_diagnostics_mod = module(b, host_target, optimize, "src/primitives/diagnostics/root.zig");
    const host_platform_info_mod = module(b, host_target, optimize, "src/primitives/platform_info/root.zig");
    const host_trace_mod = module(b, host_target, optimize, "src/primitives/trace/root.zig");
    const host_debug_mod = module(b, host_target, optimize, "src/debug/root.zig");
    host_debug_mod.addImport("app_dirs", host_app_dirs_mod);
    host_debug_mod.addImport("trace", host_trace_mod);
    const host_automation_protocol_mod = module(b, host_target, optimize, "src/automation/protocol.zig");
    const host_tooling_mod = module(b, host_target, optimize, "src/tooling/root.zig");
    host_tooling_mod.addImport("assets", host_assets_mod);
    host_tooling_mod.addImport("app_dirs", host_app_dirs_mod);
    host_tooling_mod.addImport("app_manifest", host_app_manifest_mod);
    host_tooling_mod.addImport("diagnostics", host_diagnostics_mod);
    host_tooling_mod.addImport("debug", host_debug_mod);
    host_tooling_mod.addImport("platform_info", host_platform_info_mod);
    host_tooling_mod.addImport("trace", host_trace_mod);
    const host_ui_markup_mod = module(b, host_target, optimize, "src/primitives/canvas/ui_markup.zig");
    const host_markup_lsp_mod = module(b, host_target, optimize, "tools/native-sdk/markup_lsp.zig");
    host_markup_lsp_mod.addImport("ui_markup", host_ui_markup_mod);
    const host_cli_mod = module(b, host_target, optimize, "tools/native-sdk/main.zig");
    host_cli_mod.addImport("tooling", host_tooling_mod);
    host_cli_mod.addImport("automation_protocol", host_automation_protocol_mod);
    host_cli_mod.addImport("ui_markup", host_ui_markup_mod);
    host_cli_mod.addImport("markup_lsp", host_markup_lsp_mod);
    host_cli_mod.addOptions("cli_build_info", cli_build_info);
    const host_cli_exe = b.addExecutable(.{
        .name = "native",
        .root_module = host_cli_mod,
    });
    // Docs component-preview generator: renders the built-in component
    // catalog offscreen through the deterministic reference renderer and
    // writes theme-aware webp pairs plus the markup vocabulary JSON into
    // docs/. Regenerate with `zig build docs-component-previews`.
    const docs_previews_mod = module(b, target, optimize, "tools/docs_component_previews.zig");
    docs_previews_mod.addImport("native_sdk", desktop_mod);
    const docs_previews_exe = b.addExecutable(.{
        .name = "docs-component-previews",
        .root_module = docs_previews_mod,
    });
    const run_docs_previews = b.addRunArtifact(docs_previews_exe);
    run_docs_previews.addArg(b.pathFromRoot("docs/public/components"));
    run_docs_previews.addArg(b.pathFromRoot("docs/src/lib/component-vocab.json"));
    run_docs_previews.has_side_effects = true;
    const docs_previews_step = b.step("docs-component-previews", "Render built-in component previews and vocab JSON into docs/");
    docs_previews_step.dependOn(&run_docs_previews.step);

    // Live docs previews: the same scene catalog compiled to
    // wasm32-freestanding (tools/docs_wasm_preview.zig) so the docs
    // upgrade the static webp tiles to interactive engine instances.
    // ReleaseSmall + strip keep the module small enough to lazy-load.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_optimize: std.builtin.OptimizeMode = .ReleaseSmall;
    const wasm_geometry_mod = module(b, wasm_target, wasm_optimize, "src/primitives/geometry/root.zig");
    const wasm_json_mod = module(b, wasm_target, wasm_optimize, "src/primitives/json/root.zig");
    const wasm_canvas_mod = module(b, wasm_target, wasm_optimize, "src/primitives/canvas/root.zig");
    wasm_canvas_mod.addImport("geometry", wasm_geometry_mod);
    wasm_canvas_mod.addImport("json", wasm_json_mod);
    const wasm_native_mod = module(b, wasm_target, wasm_optimize, "src/root.zig");
    wasm_native_mod.addImport("geometry", wasm_geometry_mod);
    wasm_native_mod.addImport("json", wasm_json_mod);
    wasm_native_mod.addImport("canvas", wasm_canvas_mod);
    wasm_native_mod.addImport("app_dirs", module(b, wasm_target, wasm_optimize, "src/primitives/app_dirs/root.zig"));
    wasm_native_mod.addImport("assets", module(b, wasm_target, wasm_optimize, "src/primitives/assets/root.zig"));
    wasm_native_mod.addImport("trace", module(b, wasm_target, wasm_optimize, "src/primitives/trace/root.zig"));
    wasm_native_mod.addImport("app_manifest", module(b, wasm_target, wasm_optimize, "src/primitives/app_manifest/root.zig"));
    wasm_native_mod.addImport("diagnostics", module(b, wasm_target, wasm_optimize, "src/primitives/diagnostics/root.zig"));
    wasm_native_mod.addImport("platform_info", module(b, wasm_target, wasm_optimize, "src/primitives/platform_info/root.zig"));
    const docs_wasm_preview_mod = module(b, wasm_target, wasm_optimize, "tools/docs_wasm_preview.zig");
    docs_wasm_preview_mod.addImport("native_sdk", wasm_native_mod);
    docs_wasm_preview_mod.strip = true;
    const docs_wasm_preview_exe = b.addExecutable(.{
        .name = "component-preview",
        .root_module = docs_wasm_preview_mod,
    });
    docs_wasm_preview_exe.entry = .disabled;
    docs_wasm_preview_exe.rdynamic = true;
    // The engine trades heap for fixed capacity but still builds some
    // sizable stack temporaries (NullPlatform alone is ~800 KB); the
    // 1 MB wasm default overflows into linear memory silently.
    docs_wasm_preview_exe.stack_size = 16 * 1024 * 1024;
    const copy_docs_wasm_preview = b.addUpdateSourceFiles();
    copy_docs_wasm_preview.addCopyFileToSource(docs_wasm_preview_exe.getEmittedBin(), "docs/public/wasm/component-preview.wasm");
    const docs_wasm_preview_step = b.step("docs-wasm-preview", "Compile the live component-preview wasm module into docs/public/wasm/");
    docs_wasm_preview_step.dependOn(&copy_docs_wasm_preview.step);

    const file_contains_checker_mod = module(b, host_target, optimize, "tools/check_file_contains.zig");
    const file_contains_checker = b.addExecutable(.{
        .name = "check-file-contains",
        .root_module = file_contains_checker_mod,
    });

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
    test_step.dependOn(&b.addRunArtifact(canvas_tests).step);
    test_step.dependOn(&b.addRunArtifact(desktop_tests).step);
    test_step.dependOn(&b.addRunArtifact(automation_protocol_tests).step);
    test_step.dependOn(&b.addRunArtifact(tooling_tests).step);
    test_step.dependOn(&b.addRunArtifact(markup_lsp_tests).step);
    test_step.dependOn(&b.addRunArtifact(automation_cli_tests).step);
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-package-types", "Verify package TypeScript platform feature names", &.{
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "NativeSdkCommandInfo" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "list(): Promise<NativeSdkCommandInfo[]>" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "NativeSdkCreateWebViewViewOptions" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "Stable runtime view id" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "update(label: string" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "focus(options: string | NativeSdkViewSelector)" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "close(options: string | NativeSdkViewSelector)" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "kind: \"webview\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "url: string" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "NativeSdkPlatformFeatureSelector" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "supports(value: NativeSdkPlatformFeature | NativeSdkPlatformFeatureSelector)" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"native_control_commands\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"nativeControlCommands\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"recent_documents\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"recentDocuments\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"file_drops\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"fileDrops\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"app_activation_events\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"appActivationEvents\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"gpu_surfaces\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"gpuSurfaces\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "gpuFirstFrameLatencyNs: number" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-bridge-view-selector-helpers", "Verify injected view helpers accept string selectors", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "viewSelectorPayload(options)" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "viewSelectorPayload(options)" },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "viewSelectorPayload(options)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "viewSelectorPayload(options)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "focus:function(options){return invoke('native-sdk.view.focus',viewSelectorPayload(options))" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "focus:function(options){return invoke('native-sdk.view.focus',viewSelectorPayload(options))" },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "focus:function(options){return invoke('native-sdk.view.focus',viewSelectorPayload(options))" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "focus:function(options){return invoke('native-sdk.view.focus',viewSelectorPayload(options))" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "close:function(options){return invoke('native-sdk.view.close',viewSelectorPayload(options))" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "close:function(options){return invoke('native-sdk.view.close',viewSelectorPayload(options))" },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "close:function(options){return invoke('native-sdk.view.close',viewSelectorPayload(options))" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "close:function(options){return invoke('native-sdk.view.close',viewSelectorPayload(options))" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-docs-command-contracts", "Verify command docs match native view update contracts", &.{
        .{ .path = "docs/src/app/commands/page.mdx", .pattern = ".text = \"Refreshed\"" },
        .{ .path = "docs/src/app/commands/page.mdx", .pattern = "const commands = await window.zero.commands.list();" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-docs-native-view-contracts", "Verify native surface docs describe view identity", &.{
        .{ .path = "docs/src/app/native-surfaces/page.mdx", .pattern = "ViewInfo.id" },
        .{ .path = "docs/src/app/native-surfaces/page.mdx", .pattern = "window.zero.views.update(\"status\"" },
        .{ .path = "docs/src/app/native-surfaces/page.mdx", .pattern = "first-frame latency budget" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-docs-shell-manifest-contracts", "Verify app.zon docs describe shell compatibility window labels", &.{
        .{ .path = "docs/src/app/app-zon/page.mdx", .pattern = "labels must stay unique across both lists" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-js-view-helper-contracts", "Verify injected view helpers support label-first updates", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "update:function(options,patch)" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "update:function(options,patch)" },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "update:function(options,patch)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "update:function(options,patch)" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-windows-packaged-assets-webview2", "Verify Windows packaged assets are served through WebView2 request interception", &.{
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "constexpr const char *kAssetVirtualOrigin = \"https://native-sdk-app.localhost\";" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "return virtualAssetEntryUrl(webview.asset_entry);" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "AddWebResourceRequestedFilter(L\"https://native-sdk-app.localhost/*\"" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "assetWebResourceResponse(environment_ref.Get(), found->second, uri)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "bridgeOriginForWebViewUrl(source_webview->second, source_url)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "webview.spa_fallback = spa_fallback != 0;" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-macos-cef-packaged-assets-webviews", "Verify macOS CEF child WebViews resolve packaged asset URLs before loading", &.{
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "self.assetRoots = [[NSMutableDictionary alloc] init];" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "resolvedWebViewURLString:(NSString *)url windowId:(uint64_t)windowId" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "CefBrowserHost::CreateBrowser(windowInfo, client.get(), std::string(resolvedURL.UTF8String)" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "self.webviewPendingURLs[[self webViewKeyForWindow:windowId label:label]] = resolvedURL;" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "bridgeOriginForWindowId:window_id_ webViewLabel:labelString sourceURL:sourceURLString" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-native-accessibility-roles", "Verify AppKit native views publish accessibility roles", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkAccessibilityRoleForNativeViewKind" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSAccessibilityToolbarRole" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSAccessibilityProgressIndicatorRole" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "view.accessibilityRole = NativeSdkAccessibilityRoleForNativeViewKind(kind)" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-input-repaints-retained-canvas", "Verify GPU input wakes retained canvas frames", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "- (void)requestRetainedCanvasFrame" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[self requestRetainedCanvasFrame];" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-input-paces-retained-canvas", "Verify GPU input frame requests are paced to the display interval", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkRetainedFrameIntervalNanoseconds" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "retainedFrameLastEmitNs" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "queuePointerMotionInputEvent:(NSEvent *)event" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "pendingPointerMotionKind = kind" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "emitQueuedPointerMotionInputEvent" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "queueScrollInputEvent:(NSEvent *)event" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "pendingScrollDeltaY += deltaY" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "emitQueuedScrollInputEvent" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "dispatch_after(dispatch_time(DISPATCH_TIME_NOW" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "- (void)emitRetainedCanvasFrameRequest" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-drawable-integral-pixels", "Verify AppKit GPU surfaces use integral drawable pixels", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "ceil(size.width * scale)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "ceil(size.height * scale)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "self.metalLayer.drawableSize = drawableSize" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-resize-repaints-retained-canvas", "Verify AppKit GPU resize requests a correctly sized retained frame", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "_metalLayer.contentsGravity = kCAGravityTopLeft" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "if (changed) {" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[self requestRetainedCanvasFrame];" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "canvasTextureMatchesDrawable" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-transforms", "Verify AppKit GPU packet presenter applies command transforms", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketApplyTransform(command[@\"transform\"])" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[affine setTransformStruct:transform]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[affine concat]" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-paths", "Verify AppKit GPU packet presenter draws path commands", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[kind isEqualToString:@\"path\"]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[verb isEqualToString:@\"quad_to\"]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[kind isEqualToString:@\"fill_path\"]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[kind isEqualToString:@\"stroke_path\"]" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-corner-radii", "Verify AppKit GPU packet presenter honors per-corner radii", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketRoundedRectPath" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "CGFloat topRight = NativeSdkPacketRadiusAt(radiusValue, 1, maxRadius)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "CGFloat bottomLeft = NativeSdkPacketRadiusAt(radiusValue, 3, maxRadius)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "return NativeSdkPacketRoundedRectPath(rect, shape[@\"radius\"])" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-load-frames", "Verify AppKit GPU packet presenter handles retained load frames", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "canvasPacketPixels" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[loadAction isEqualToString:@\"load\"]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[self.canvasPacketPixels mutableCopy]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "hasDirtyRect:uploadDirtyRect" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-blur-effects", "Verify AppKit GPU packet presenter applies blur effects", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketApplyBlur" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "CGBitmapContextGetData(context)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSIntersectionRect(rect, clipRect)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketTransformRect(transformValue, NativeSdkPacketRect(effect[@\"rect\"]))" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "return NativeSdkPacketApplyBlur(effect, opacity, context, scale, transformValue, hasClip, clipRect)" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-text-layout", "Verify AppKit GPU packet presenter honors text layout metadata", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSMutableParagraphStyle" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketTextLineBreakMode" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketTextAlignment" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketNumber(layout[@\"maxWidth\"], 0)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[value drawWithRect:NSMakeRect(origin.x, origin.y - size, textWidth, textHeight)" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-font-assets", "Verify AppKit GPU packet text registers bundled font assets", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "#import <CoreText/CoreText.h>" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "CTFontManagerRegisterFontsForURL" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "@[ @\"fonts\", @\"Fonts\", @\"assets/fonts\" ]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkRegisterBundledFonts();" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketPreferredFont(text, size)" },
        .{ .path = "src/tooling/templates.zig", .pattern = "app_mod.linkFramework(\"CoreText\", .{});" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-span-fonts", "Verify AppKit packet text resolves reserved span font ids to real weighted and italic faces", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "static NSFont *NativeSdkItalicSansFont(NSFont *font)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "static NSFont *NativeSdkWeightedSansFont(" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkWeightedSansFont(@[ @\"Geist-Medium\", @\"Geist Medium\" ], base, NSFontWeightMedium, NO, size)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkWeightedSansFont(@[ @\"Geist-Bold\", @\"Geist Bold\" ], base, NSFontWeightBold, YES, size)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkItalicSansFont(base)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkItalicSansFont(NativeSdkWeightedSansFont(@[ @\"Geist-Bold\", @\"Geist Bold\" ], base, NSFontWeightBold, YES, size))" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-widget-cursor-bridge", "Verify AppKit GPU widgets apply retained cursor intent", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "native_sdk_appkit_set_view_cursor" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "resetCursorRects" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSTrackingMouseMoved" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_CANCEL" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "_surfaceCursor = cursor ?: [NSCursor arrowCursor]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSCursor pointingHandCursor" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-widget-accessibility-actions", "Verify AppKit GPU widget accessibility actions route to the runtime", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityPerformPress" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "emitWidgetAccessibilityActionWithId" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NATIVE_SDK_APPKIT_EVENT_WIDGET_ACCESSIBILITY_ACTION" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-widget-accessibility-text-ranges", "Verify AppKit GPU widget accessibility publishes text selection ranges", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilitySelectedTextRange" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilitySelectedTextRanges" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityVisibleCharacterRange" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-widget-accessibility-grid-metrics", "Verify AppKit GPU widget accessibility publishes grid and scroll metrics", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityRowIndexRange" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityColumnIndexRange" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityRowCount" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityMaxValue" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-widget-ime-bridge", "Verify AppKit GPU widgets route native text input and IME composition", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSTextInputClient" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "insertText:(id)string replacementRange" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "setMarkedText:(id)string selectedRange" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NATIVE_SDK_APPKIT_GPU_INPUT_IME_SET_COMPOSITION" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-windows-gpu-widget-ime-bridge", "Verify the Windows GPU host routes WM_IME composition onto the shared IME event kinds", &.{
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "case WM_IME_STARTCOMPOSITION:" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "case WM_IME_COMPOSITION:" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "case WM_IME_ENDCOMPOSITION:" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "kGpuInputImeSetComposition = 8" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "kGpuInputImeCommitComposition = 9" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "kGpuInputImeCancelComposition = 10" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "gpuImeCommitAction(pending, result)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "ISC_SHOWUICOMPOSITIONWINDOW" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-widget-text-command-bridge", "Verify AppKit GPU text widgets route native text commands", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "- (void)selectAll:(id)sender" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "@selector(selectAll:)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "emitSyntheticKeyDownWithKey:@\"a\" modifiers:(NativeSdkShortcutModifierPrimary | NativeSdkShortcutModifierCommand)" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-appearance-bridge", "Verify AppKit reports system light and dark appearance changes", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "effectiveAppearance" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityDisplayShouldReduceMotion" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityDisplayShouldIncreaseContrast" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NATIVE_SDK_APPKIT_EVENT_APPEARANCE_CHANGED" },
        .{ .path = "src/platform/macos/root.zig", .pattern = ".reduce_motion = event.reduce_motion != 0" },
        .{ .path = "src/platform/macos/root.zig", .pattern = ".high_contrast = event.high_contrast != 0" },
        .{ .path = "src/platform/macos/root.zig", .pattern = ".appearance_changed => state.emit" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-docs-builtin-bridge-policy", "Verify bridge policy docs include guarded dialog commands", &.{
        .{ .path = "docs/src/app/security/page.mdx", .pattern = ".{ .name = \"native-sdk.dialog.saveFile\"" },
        .{ .path = "docs/src/app/bridge/builtin-commands/page.mdx", .pattern = ".{ .name = \"native-sdk.dialog.saveFile\"" },
    });

    addTestStep(b, "test-geometry", "Run geometry module tests", geometry_tests);
    addTestStep(b, "test-assets", "Run assets module tests", assets_tests);
    addTestStep(b, "test-app-dirs", "Run app directory module tests", app_dirs_tests);
    addTestStep(b, "test-trace", "Run trace module tests", trace_tests);
    addTestStep(b, "test-app-manifest", "Run app manifest module tests", app_manifest_tests);
    addTestStep(b, "test-diagnostics", "Run diagnostics module tests", diagnostics_tests);
    addTestStep(b, "test-platform-info", "Run platform info module tests", platform_info_tests);
    addTestStep(b, "test-json", "Run JSON primitive tests", json_tests);
    addTestStep(b, "test-canvas", "Run canvas display list tests", canvas_tests);
    addTestStep(b, "test-desktop", "Run Native SDK framework tests", desktop_tests);
    addTestStep(b, "test-automation-protocol", "Run automation protocol tests", automation_protocol_tests);
    addTestStep(b, "test-automation-cli", "Run native automate CLI tests", automation_cli_tests);
    addTestStep(b, "test-tooling", "Run Native SDK tooling tests", tooling_tests);

    const run_hello = b.addSystemCommand(&.{ "zig", "build", "run", b.fmt("-Dplatform={s}", .{platform_arg}), b.fmt("-Dtrace={s}", .{@tagName(trace_option)}) });
    run_hello.setCwd(b.path("examples/hello"));
    const run_hello_step = b.step("run-hello", "Run the native-sdk hello WebView example");
    run_hello_step.dependOn(&run_hello.step);

    const run_webview = b.addSystemCommand(&.{ "zig", "build", "run", b.fmt("-Dplatform={s}", .{platform_arg}), b.fmt("-Dtrace={s}", .{@tagName(trace_option)}), b.fmt("-Dweb-engine={s}", .{@tagName(web_engine)}), b.fmt("-Dcef-dir={s}", .{cef_dir}) });
    run_webview.setCwd(b.path("examples/webview"));
    const run_webview_step = b.step("run-webview", "Run the native-sdk WebView example");
    run_webview_step.dependOn(&run_webview.step);

    const browser_cef_dir = cef_dir_override orelse defaultCefDir(selected_platform, "third_party/cef/macos");
    const run_browser = b.addSystemCommand(&.{ "zig", "build", "run", b.fmt("-Dplatform={s}", .{platform_arg}), b.fmt("-Dtrace={s}", .{@tagName(trace_option)}), b.fmt("-Dweb-engine={s}", .{@tagName(browser_web_engine)}), b.fmt("-Dcef-dir={s}", .{browser_cef_dir}) });
    run_browser.setCwd(b.path("examples/browser"));
    const run_browser_step = b.step("run-browser", "Run the native-sdk browser example");
    run_browser_step.dependOn(&run_browser.step);

    const build_webview_system = b.addSystemCommand(&.{ "zig", "build", b.fmt("-Dplatform={s}", .{platform_arg}), "-Dweb-engine=system" });
    build_webview_system.setCwd(b.path("examples/webview"));
    const webview_system_link_step = b.step("test-webview-system-link", "Build the WebView example with the system engine");
    webview_system_link_step.dependOn(&build_webview_system.step);

    const build_browser_system = b.addSystemCommand(&.{ "zig", "build", b.fmt("-Dplatform={s}", .{platform_arg}), "-Dweb-engine=system" });
    build_browser_system.setCwd(b.path("examples/browser"));
    const browser_system_link_step = b.step("test-browser-system-link", "Build the browser example with the system engine");
    browser_system_link_step.dependOn(&build_browser_system.step);

    const frontend_examples_step = b.step("test-examples-frontends", "Run frontend example tests");
    addExampleTestStep(b, frontend_examples_step, "test-example-next", "Run Next example tests", "examples/next");
    addExampleTestStep(b, frontend_examples_step, "test-example-react", "Run React example tests", "examples/react");
    addExampleTestStep(b, frontend_examples_step, "test-example-svelte", "Run Svelte example tests", "examples/svelte");
    addExampleTestStep(b, frontend_examples_step, "test-example-vue", "Run Vue example tests", "examples/vue");
    addFileContainsCheckStep(b, file_contains_checker, frontend_examples_step, "test-example-frontend-positioning", "Verify frontend example native shell positioning", &.{
        .{ .path = "examples/next/README.md", .pattern = "opens the native app shell with WebView content." },
        .{ .path = "examples/react/README.md", .pattern = "opens the native app shell with WebView content." },
        .{ .path = "examples/svelte/README.md", .pattern = "opens the native app shell with WebView content." },
        .{ .path = "examples/vue/README.md", .pattern = "opens the native app shell with WebView content." },
    });

    const native_examples_step = b.step("test-examples-native", "Run native-first example tests");
    addExampleTestStep(b, native_examples_step, "test-example-command-app", "Run command app example tests", "examples/command-app");
    addExampleTestStep(b, native_examples_step, "test-example-native-shell", "Run native shell example tests", "examples/native-shell");
    addExampleTestStep(b, native_examples_step, "test-example-native-panels", "Run native panels example tests", "examples/native-panels");
    addExampleTestStep(b, native_examples_step, "test-example-gpu-surface", "Run GPU surface example tests", "examples/gpu-surface");
    addExampleTestStep(b, native_examples_step, "test-example-gpu-dashboard", "Run GPU dashboard example tests", "examples/gpu-dashboard");
    addExampleTestStep(b, native_examples_step, "test-example-gpu-components", "Run GPU components example tests", "examples/gpu-components");
    addExampleTestStep(b, native_examples_step, "test-example-ui-inbox", "Run ui builder inbox example tests", "examples/ui-inbox");
    addExampleTestStep(b, native_examples_step, "test-example-kanban", "Run ui builder kanban example tests", "examples/kanban");
    addExampleTestStep(b, native_examples_step, "test-example-habits", "Run markup habits example tests", "examples/habits");
    addExampleTestStep(b, native_examples_step, "test-example-soundboard", "Run soundboard example tests", "examples/soundboard");
    addExampleTestStep(b, native_examples_step, "test-example-deck", "Run deck example tests", "examples/deck");
    addExampleTestStep(b, native_examples_step, "test-example-markdown-viewer", "Run markdown viewer example tests", "examples/markdown-viewer");
    addExampleTestStep(b, native_examples_step, "test-example-calculator", "Run calculator example tests", "examples/calculator");
    addExampleTestStep(b, native_examples_step, "test-example-notes", "Run notes example tests", "examples/notes");
    addExampleTestStep(b, native_examples_step, "test-example-system-monitor", "Run system monitor example tests", "examples/system-monitor");
    addExampleTestStep(b, native_examples_step, "test-example-effects-probe", "Run effects probe example tests", "examples/effects-probe");
    addExampleTestStep(b, native_examples_step, "test-example-canvas-preview", "Run canvas preview example tests", "examples/canvas-preview");
    addExampleTestStep(b, native_examples_step, "test-example-capabilities", "Run capabilities example tests", "examples/capabilities");
    addFileContainsCheckStep(b, file_contains_checker, native_examples_step, "test-example-capabilities-events", "Verify capabilities example event bridge names", &.{
        .{ .path = "examples/capabilities/src/main.zig", .pattern = "native-sdk:drop:files" },
    });

    const mobile_examples_step = b.step("test-examples-mobile", "Verify mobile example project layouts");
    addLayoutCheckStep(b, mobile_examples_step, "test-example-ios-layout", "Verify iOS example layout", &.{
        "examples/ios/README.md",
        "examples/ios/app.zon",
        "examples/ios/NativeSdkIOSExample.xcodeproj/project.pbxproj",
        "examples/ios/NativeSdkIOSExample/AppDelegate.swift",
        "examples/ios/NativeSdkIOSExample/SceneDelegate.swift",
        "examples/ios/NativeSdkIOSExample/NativeSdkHostViewController.swift",
        "examples/ios/NativeSdkIOSExample/native_sdk.h",
    });
    addLayoutCheckStep(b, mobile_examples_step, "test-example-android-layout", "Verify Android example layout", &.{
        "examples/android/README.md",
        "examples/android/app.zon",
        "examples/android/settings.gradle",
        "examples/android/build.gradle",
        "examples/android/app/build.gradle",
        "examples/android/app/src/main/AndroidManifest.xml",
        "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt",
        "examples/android/app/src/main/cpp/CMakeLists.txt",
        "examples/android/app/src/main/cpp/native_sdk_jni.c",
        "examples/android/app/src/main/cpp/native_sdk.h",
    });
    addLayoutCheckStep(b, mobile_examples_step, "test-example-mobile-shell-layout", "Verify shared mobile-shell metadata", &.{
        "examples/mobile-shell/README.md",
        "examples/mobile-shell/app.zon",
    });
    addFileContainsCheckStep(b, file_contains_checker, mobile_examples_step, "test-example-mobile-shell-metadata", "Verify shared mobile-shell metadata values", &.{
        .{ .path = "examples/mobile-shell/app.zon", .pattern = ".platforms = .{ \"ios\", \"android\" }" },
        .{ .path = "examples/mobile-shell/app.zon", .pattern = ".capabilities = .{ \"webview\", \"native_views\", \"native_module\" }" },
        .{ .path = "examples/mobile-shell/app.zon", .pattern = ".id = \"mobile.back\"" },
        .{ .path = "examples/mobile-shell/app.zon", .pattern = ".id = \"mobile.refresh\"" },
        .{ .path = "examples/mobile-shell/app.zon", .pattern = ".label = \"mobile-header\"" },
        .{ .path = "examples/mobile-shell/app.zon", .pattern = ".label = \"workspace\", .kind = \"webview\"" },
    });
    addFileContainsCheckStep(b, file_contains_checker, mobile_examples_step, "test-example-mobile-host-commands", "Verify mobile host command metadata values", &.{
        .{ .path = "examples/ios/app.zon", .pattern = ".id = \"mobile.back\"" },
        .{ .path = "examples/ios/app.zon", .pattern = ".id = \"mobile.refresh\"" },
        .{ .path = "examples/ios/app.zon", .pattern = ".label = \"mobile-header\"" },
        .{ .path = "examples/android/app.zon", .pattern = ".id = \"mobile.back\"" },
        .{ .path = "examples/android/app.zon", .pattern = ".id = \"mobile.refresh\"" },
        .{ .path = "examples/android/app.zon", .pattern = ".label = \"mobile-header\"" },
    });
    addFileContainsCheckStep(b, file_contains_checker, mobile_examples_step, "test-example-android-widget-ime", "Verify Android retained widget IME and action bridge", &.{
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "override fun onCreateInputConnection" },
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "nativeIme(nativeApp, kind, text, cursor)" },
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "WIDGET_ACTION_KIND_SET_COMPOSITION = 7" },
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "WIDGET_ACTION_DRAG = 1 shl 8" },
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "WIDGET_ACTION_DROP_FILES = 1 shl 9" },
    });
    addFileContainsCheckStep(b, file_contains_checker, mobile_examples_step, "test-example-mobile-widget-abi", "Verify mobile examples use stable widget ABI lookups", &.{
        .{ .path = "examples/ios/NativeSdkIOSExample/native_sdk.h", .pattern = "native_sdk_viewport_state_t" },
        .{ .path = "examples/ios/NativeSdkIOSExample/native_sdk.h", .pattern = "native_sdk_app_scroll" },
        .{ .path = "examples/ios/NativeSdkIOSExample/native_sdk.h", .pattern = "native_sdk_app_set_text_measure" },
        .{ .path = "examples/android/app/src/main/cpp/native_sdk.h", .pattern = "native_sdk_app_set_text_measure" },
        .{ .path = "examples/mobile-canvas/ios/native_sdk_app.h", .pattern = "native_sdk_app_set_text_measure" },
        .{ .path = "examples/ios/NativeSdkIOSExample/NativeSdkHostViewController.swift", .pattern = "native_sdk_app_widget_semantics_by_id" },
        .{ .path = "examples/android/app/src/main/cpp/native_sdk.h", .pattern = "native_sdk_app_widget_semantics_by_id" },
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "nativeScroll(nativeApp" },
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "nativeWidgetSemanticsByIdFields" },
        .{ .path = "examples/android/app/src/main/cpp/native_sdk_jni.c", .pattern = "native_sdk_app_widget_semantics_by_id" },
        .{ .path = "examples/android/app/src/main/cpp/native_sdk_jni.c", .pattern = "native_sdk_app_scroll" },
    });
    addFileContainsCheckStep(b, file_contains_checker, mobile_examples_step, "test-example-mobile-canvas-span-fonts", "Verify the iOS embed shim measures reserved span font ids with the macOS face mapping", &.{
        .{ .path = "examples/mobile-canvas/ios/main.m", .pattern = "static UIFont *NativeSdkItalicSansFont(UIFont *font)" },
        .{ .path = "examples/mobile-canvas/ios/main.m", .pattern = "static UIFont *NativeSdkWeightedSansFont(" },
        .{ .path = "examples/mobile-canvas/ios/main.m", .pattern = "NativeSdkWeightedSansFont(@[ @\"Geist-Medium\", @\"Geist Medium\" ], UIFontWeightMedium, size)" },
        .{ .path = "examples/mobile-canvas/ios/main.m", .pattern = "NativeSdkWeightedSansFont(@[ @\"Geist-Bold\", @\"Geist Bold\" ], UIFontWeightBold, size)" },
        .{ .path = "examples/mobile-canvas/ios/main.m", .pattern = "NativeSdkItalicSansFont(NativeSdkWeightedSansFont(@[ @\"Geist-Bold\", @\"Geist Bold\" ], UIFontWeightBold, size))" },
    });

    const build_mobile_canvas_lib = b.addSystemCommand(&.{ "zig", "build", "lib" });
    build_mobile_canvas_lib.setCwd(b.path("examples/mobile-canvas"));
    const mobile_canvas_lib_step = b.step("test-example-mobile-canvas-lib", "Build the mobile-canvas embed static library through addMobileLib");
    mobile_canvas_lib_step.dependOn(&build_mobile_canvas_lib.step);
    mobile_examples_step.dependOn(&build_mobile_canvas_lib.step);

    // Android cross-compile proof: pure Zig (no NDK sysroot — the static
    // lib links no libc), PIC so the objects can land in the shim's .so.
    const build_mobile_canvas_lib_android = b.addSystemCommand(&.{ "zig", "build", "lib", "-Dtarget=aarch64-linux-android" });
    build_mobile_canvas_lib_android.setCwd(b.path("examples/mobile-canvas"));
    const mobile_canvas_lib_android_step = b.step("test-example-mobile-canvas-lib-android", "Cross-compile the mobile-canvas embed static library for aarch64-linux-android");
    mobile_canvas_lib_android_step.dependOn(&build_mobile_canvas_lib_android.step);
    mobile_examples_step.dependOn(&build_mobile_canvas_lib_android.step);

    const examples_step = b.step("test-examples", "Run all example tests and layout checks");
    examples_step.dependOn(frontend_examples_step);
    examples_step.dependOn(native_examples_step);
    examples_step.dependOn(mobile_examples_step);

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
        \\response_file=".zig-cache/native-sdk-automation/bridge-response.txt"
        \\mkdir -p .zig-cache/native-sdk-automation
        \\rm -f .zig-cache/native-sdk-automation/snapshot.txt .zig-cache/native-sdk-automation/windows.txt .zig-cache/native-sdk-automation/command.txt "$response_file"
        \\printf 'bridge %s\n' "$request" > .zig-cache/native-sdk-automation/command.txt
        \\"$app" > .zig-cache/native-sdk-webview-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-webview-smoke.log) ----" >&2; cat .zig-cache/native-sdk-webview-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\snapshot="$("$cli" automate wait 2>&1)"
        \\case "$snapshot" in *"ready=true"*) ;; *) echo "automation snapshot was not ready" >&2; exit 1 ;; esac
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "native.ping did not succeed: $response" >&2; exit 1 ;; esac
        \\case "$response" in *'pong from Zig'*) ;; *) echo "native.ping response was unexpected: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-create","command":"native-sdk.webview.create","payload":{"label":"smoke","url":"https://example.com","frame":{"x":24,"y":24,"width":320,"height":220}}}' > .zig-cache/native-sdk-automation/command.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "webview create did not succeed: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-resize","command":"native-sdk.webview.setFrame","payload":{"label":"smoke","frame":{"x":36,"y":36,"width":420,"height":260}}}' > .zig-cache/native-sdk-automation/command.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "webview resize did not succeed: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-navigate","command":"native-sdk.webview.navigate","payload":{"label":"smoke","url":"https://example.com/?smoke=1"}}' > .zig-cache/native-sdk-automation/command.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "webview navigate did not succeed: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-close","command":"native-sdk.webview.close","payload":{"label":"smoke"}}' > .zig-cache/native-sdk-automation/command.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "webview close did not succeed: $response" >&2; exit 1 ;; esac
        \\echo "webview smoke ok"
        ,
        "sh",
    });
    webview_smoke_run.addFileArg(cli_exe.getEmittedBin());
    webview_smoke_run.step.dependOn(&webview_smoke_build.step);
    webview_smoke_run.step.dependOn(&cli_exe.step);
    webview_smoke_step.dependOn(&webview_smoke_run.step);

    const native_shell_smoke_step = b.step("test-native-shell-smoke", "Run macOS native-shell automation smoke test");
    const native_shell_smoke_build = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true", "-Djs-bridge=true" });
    native_shell_smoke_build.setCwd(b.path("examples/native-shell"));
    const native_shell_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/native-shell
        \\app="zig-out/bin/native-shell"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\automation_dir=".zig-cache/native-sdk-automation"
        \\response_file="$automation_dir/bridge-response.txt"
        \\mkdir -p "$automation_dir"
        \\rm -f "$automation_dir/snapshot.txt" "$automation_dir/accessibility.txt" "$automation_dir/windows.txt" "$automation_dir/command.txt" "$response_file"
        \\"$app" > .zig-cache/native-sdk-native-shell-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-native-shell-smoke.log) ----" >&2; cat .zig-cache/native-sdk-native-shell-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\ready="$("$cli" automate wait 2>&1)"
        \\case "$ready" in *"ready=true"*) ;; *) echo "native-shell automation snapshot was not ready" >&2; exit 1 ;; esac
        \\snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\case "$snapshot" in *'window @w1 "Native SDK Native Shell"'*) ;; *) echo "native-shell window was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/toolbar kind=toolbar'*) ;; *) echo "toolbar view was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/sidebar kind=sidebar'*) ;; *) echo "sidebar view was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/main kind=webview'*) ;; *) echo "main WebView was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/statusbar kind=statusbar'*) ;; *) echo "statusbar view was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/refresh-icon kind=icon_button'*'accessibility_label="Refresh workspace"'*) ;; *) echo "refresh icon accessibility metadata was missing from snapshot" >&2; exit 1 ;; esac
        \\"$cli" automate focus refresh-button >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  focus_line="$(printf '%s\n' "$snapshot" | grep -F 'view @w1/refresh-button kind=button' || true)"
        \\  case "$focus_line" in *'focused=true'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$focus_line" in *'focused=true'*) ;; *) echo "native-shell refresh button did not receive focus" >&2; exit 1 ;; esac
        \\"$cli" automate focus-next >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  focus_line="$(printf '%s\n' "$snapshot" | grep -F 'view @w1/palette-button kind=button' || true)"
        \\  case "$focus_line" in *'focused=true'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$focus_line" in *'focused=true'*) ;; *) echo "native-shell focus-next did not move focus to palette button" >&2; exit 1 ;; esac
        \\"$cli" automate focus-previous >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  focus_line="$(printf '%s\n' "$snapshot" | grep -F 'view @w1/refresh-button kind=button' || true)"
        \\  case "$focus_line" in *'focused=true'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$focus_line" in *'focused=true'*) ;; *) echo "native-shell focus-previous did not return focus to refresh button" >&2; exit 1 ;; esac
        \\"$cli" automate resize 900 640 >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'window @w1 "Native SDK Native Shell" bounds=('*' 900x640)'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'window @w1 "Native SDK Native Shell" bounds=('*' 900x640)'*) ;; *) echo "native-shell window resize was not reflected in snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/toolbar kind=toolbar'*'bounds=(0,0 900x52)'*) ;; *) echo "native-shell toolbar did not relayout after resize" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/main kind=webview'*'bounds=(240,52 660x548)'*) ;; *) echo "native-shell main WebView did not relayout after resize" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/statusbar kind=statusbar'*'bounds=(240,600 660x40)'*) ;; *) echo "native-shell statusbar did not relayout after resize" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"native-shell-refresh","command":"native-sdk.command.invoke","payload":{"name":"app.refresh"}}' > "$automation_dir/command.txt"
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*'"name":"app.refresh"'*'"source":"bridge"'*) ;; *) echo "native-shell command bridge did not succeed: $response" >&2; exit 1 ;; esac
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'Refreshed from bridge. Count 1.'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/status-label kind=label'*'Refreshed from bridge. Count 1.'*) ;; *) echo "native-shell status view did not reflect bridge refresh" >&2; exit 1 ;; esac
        \\"$cli" automate menu-command app.refresh >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'Refreshed from menu. Count 2.'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/status-label kind=label'*'Refreshed from menu. Count 2.'*) ;; *) echo "native-shell menu command did not update status" >&2; exit 1 ;; esac
        \\"$cli" automate native-command app.refresh refresh-button >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'Refreshed from toolbar. Count 3.'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/status-label kind=label'*'Refreshed from toolbar. Count 3.'*) ;; *) echo "native-shell toolbar command did not update status" >&2; exit 1 ;; esac
        \\"$cli" automate shortcut app.refresh >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'Refreshed from shortcut. Count 4.'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/status-label kind=label'*'Refreshed from shortcut. Count 4.'*) ;; *) echo "native-shell shortcut command did not update status" >&2; exit 1 ;; esac
        \\"$cli" automate menu-command app.preview.open >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'view @w1/preview kind=webview'*'bounds=(520,96 320x220)'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/preview kind=webview'*'bounds=(520,96 320x220)'*) ;; *) echo "native-shell preview WebView was not created" >&2; exit 1 ;; esac
        \\"$cli" automate menu-command app.preview.close >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'view @w1/preview kind=webview'*) ;; *) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/preview kind=webview'*) echo "native-shell preview WebView was not closed" >&2; exit 1 ;; *) ;; esac
        \\echo "native-shell smoke ok"
        ,
        "sh",
    });
    native_shell_smoke_run.addFileArg(cli_exe.getEmittedBin());
    native_shell_smoke_run.step.dependOn(&native_shell_smoke_build.step);
    native_shell_smoke_run.step.dependOn(&cli_exe.step);
    native_shell_smoke_step.dependOn(&native_shell_smoke_run.step);

    const gpu_surface_smoke_step = b.step("test-gpu-surface-smoke", "Run macOS GPU surface automation smoke test");
    const gpu_surface_smoke_build = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true" });
    gpu_surface_smoke_build.setCwd(b.path("examples/gpu-surface"));
    const gpu_surface_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/gpu-surface
        \\app="zig-out/bin/gpu-surface"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\automation_dir=".zig-cache/native-sdk-automation"
        \\mkdir -p "$automation_dir"
        \\# Startup latencies are load-sensitive on shared CI/agent machines.
        \\# NATIVE_SDK_SMOKE_BUDGET_MS raises the first-frame latency budget (default
        \\# stays 150 ms) and the automation-ready ceiling (default stays
        \\# 500 ms; the ceiling never drops below it) without weakening the
        \\# local defaults; every correctness assertion stays strict.
        \\smoke_budget_ms="${NATIVE_SDK_SMOKE_BUDGET_MS:-150}"
        \\case "$smoke_budget_ms" in ''|*[!0-9]*) echo "NATIVE_SDK_SMOKE_BUDGET_MS must be a positive integer of milliseconds: $smoke_budget_ms" >&2; exit 1 ;; esac
        \\if [ "$smoke_budget_ms" -le 0 ]; then echo "NATIVE_SDK_SMOKE_BUDGET_MS must be a positive integer of milliseconds: $smoke_budget_ms" >&2; exit 1; fi
        \\smoke_budget_ns=$((smoke_budget_ms * 1000000))
        \\ready_budget_ms="$smoke_budget_ms"
        \\if [ "$ready_budget_ms" -lt 500 ]; then ready_budget_ms=500; fi
        \\ready_budget_ns=$((ready_budget_ms * 1000000))
        \\rm -f "$automation_dir/snapshot.txt" "$automation_dir/accessibility.txt" "$automation_dir/windows.txt" "$automation_dir/command.txt"
        \\"$app" > .zig-cache/native-sdk-gpu-surface-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-gpu-surface-smoke.log) ----" >&2; cat .zig-cache/native-sdk-gpu-surface-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\ready="$("$cli" automate wait 2>&1)"
        \\case "$ready" in *"ready=true"*) ;; *) echo "gpu-surface automation snapshot was not ready" >&2; exit 1 ;; esac
        \\ready_uptime="$(printf '%s\n' "$ready" | sed -n 's/.*runtime_uptime_ns=\([0-9][0-9]*\).*/\1/p')"
        \\case "$ready_uptime" in ''|*[!0-9]*) echo "gpu-surface automation ready uptime was missing" >&2; exit 1 ;; esac
        \\if [ "$ready_uptime" -le 0 ] || [ "$ready_uptime" -gt "$ready_budget_ns" ]; then echo "gpu-surface automation ready exceeded $ready_budget_ms ms: $ready_uptime ns" >&2; exit 1; fi
        \\snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\case "$snapshot" in *'window @w1 "Native SDK GPU Surface"'*) ;; *) echo "gpu-surface window was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/canvas kind=gpu_surface'*'accessibility_label="Animated GPU surface"'*) ;; *) echo "gpu_surface view was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/inspector kind=webview'*) ;; *) echo "inspector WebView was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/toolbar kind=toolbar'*) ;; *) echo "toolbar view was missing from snapshot" >&2; exit 1 ;; esac
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'GPU frame 1 from canvas.'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/status-label kind=label'*'GPU frame 1 from canvas.'*) ;; *) echo "gpu-surface frame event did not reach the runtime" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/canvas kind=gpu_surface'*'gpu_nonblank=true'*) ;; *) echo "gpu-surface frame was not verified as nonblank" >&2; exit 1 ;; esac
        \\first_frame_latency="$(printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/canvas kind=gpu_surface.* gpu_first_frame_latency_ns=\([0-9][0-9]*\).*/\1/p')"
        \\case "$first_frame_latency" in ''|*[!0-9]*) echo "gpu-surface first frame latency was missing" >&2; exit 1 ;; esac
        \\if [ "$first_frame_latency" -le 0 ] || [ "$first_frame_latency" -gt "$smoke_budget_ns" ]; then echo "gpu-surface first frame exceeded $smoke_budget_ms ms: $first_frame_latency ns" >&2; exit 1; fi
        \\# The runtime publishes its own fixed 150 ms budget verdict. Within that
        \\# budget the verdict must agree exactly; beyond it (reachable only when
        \\# NATIVE_SDK_SMOKE_BUDGET_MS > 150) the runtime must report the overrun honestly.
        \\if [ "$first_frame_latency" -le 150000000 ]; then
        \\  case "$snapshot" in *'view @w1/canvas kind=gpu_surface'*'gpu_first_frame_latency_budget_ns=150000000'*'gpu_first_frame_latency_budget_exceeded=0'*'gpu_first_frame_latency_budget_ok=true'*) ;; *) echo "gpu-surface first frame exceeded the latency budget" >&2; exit 1 ;; esac
        \\else
        \\  case "$snapshot" in *'view @w1/canvas kind=gpu_surface'*'gpu_first_frame_latency_budget_ns=150000000'*'gpu_first_frame_latency_budget_ok=false'*) ;; *) echo "gpu-surface runtime did not report the first-frame budget overrun" >&2; exit 1 ;; esac
        \\fi
        \\"$cli" automate native-command gpu.refresh refresh >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'GPU surface refreshed from toolbar. Count 1.'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/status-label kind=label'*'GPU surface refreshed from toolbar. Count 1.'*) ;; *) echo "gpu-surface refresh command did not update status" >&2; exit 1 ;; esac
        \\"$cli" automate resize 960 620 >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'window @w1 "Native SDK GPU Surface" bounds=('*' 960x620)'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'window @w1 "Native SDK GPU Surface" bounds=('*' 960x620)'*) ;; *) echo "gpu-surface window resize was not reflected in snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/canvas kind=gpu_surface'*'bounds=(0,0 680x534)'*) ;; *) echo "gpu_surface view did not relayout after resize" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/inspector kind=webview'*'bounds=(680,52 280x534)'*) ;; *) echo "inspector WebView did not relayout after resize" >&2; exit 1 ;; esac
        \\echo "gpu-surface smoke ok"
        ,
        "sh",
    });
    gpu_surface_smoke_run.addFileArg(cli_exe.getEmittedBin());
    gpu_surface_smoke_run.step.dependOn(&gpu_surface_smoke_build.step);
    gpu_surface_smoke_run.step.dependOn(&cli_exe.step);
    gpu_surface_smoke_step.dependOn(&gpu_surface_smoke_run.step);

    const gpu_dashboard_smoke_step = b.step("test-gpu-dashboard-smoke", "Run macOS GPU dashboard automation smoke test");
    const gpu_dashboard_smoke_build = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true" });
    gpu_dashboard_smoke_build.setCwd(b.path("examples/gpu-dashboard"));
    const gpu_dashboard_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/gpu-dashboard
        \\app="zig-out/bin/gpu-dashboard"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\automation_dir=".zig-cache/native-sdk-automation"
        \\mkdir -p "$automation_dir"
        \\# First-frame latency is load-sensitive: a cold file cache or CI/agent
        \\# machine contention can blow the 150 ms budget while the frame itself
        \\# is presented and correct. Load tolerance without weakening the proof:
        \\#   (a) NATIVE_SDK_SMOKE_BUDGET_MS raises the smoke's latency budget (default
        \\#       stays 150 ms) and the automation-ready ceiling (default stays
        \\#       500 ms; the ceiling never drops below it), and
        \\#   (b) a budget-only overrun relaunches the app once and re-measures.
        \\# Every correctness assertion (frame presented, packet-representable,
        \\# retained content, widget semantics) stays strict on whichever launch
        \\# survives, and the runtime's own fixed 150 ms budget verdict is still
        \\# asserted verbatim whenever the measured latency is within 150 ms.
        \\smoke_budget_ms="${NATIVE_SDK_SMOKE_BUDGET_MS:-150}"
        \\case "$smoke_budget_ms" in ''|*[!0-9]*) echo "NATIVE_SDK_SMOKE_BUDGET_MS must be a positive integer of milliseconds: $smoke_budget_ms" >&2; exit 1 ;; esac
        \\if [ "$smoke_budget_ms" -le 0 ]; then echo "NATIVE_SDK_SMOKE_BUDGET_MS must be a positive integer of milliseconds: $smoke_budget_ms" >&2; exit 1; fi
        \\smoke_budget_ns=$((smoke_budget_ms * 1000000))
        \\ready_budget_ms="$smoke_budget_ms"
        \\if [ "$ready_budget_ms" -lt 500 ]; then ready_budget_ms=500; fi
        \\ready_budget_ns=$((ready_budget_ms * 1000000))
        \\pid=""
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-gpu-dashboard-smoke.log) ----" >&2; cat .zig-cache/native-sdk-gpu-dashboard-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\stop_app() {
        \\  kill "$pid" >/dev/null 2>&1 || true
        \\  wait "$pid" >/dev/null 2>&1 || true
        \\  pid=""
        \\}
        \\launch_and_measure_first_frame() {
        \\  rm -f "$automation_dir/snapshot.txt" "$automation_dir/accessibility.txt" "$automation_dir/windows.txt" "$automation_dir/command.txt"
        \\  "$app" > .zig-cache/native-sdk-gpu-dashboard-smoke.log 2>&1 &
        \\  pid=$!
        \\  ready="$("$cli" automate wait 2>&1)"
        \\  case "$ready" in *"ready=true"*) ;; *) echo "gpu-dashboard automation snapshot was not ready" >&2; exit 1 ;; esac
        \\  ready_uptime="$(printf '%s\n' "$ready" | sed -n 's/.*runtime_uptime_ns=\([0-9][0-9]*\).*/\1/p')"
        \\  case "$ready_uptime" in ''|*[!0-9]*) echo "gpu-dashboard automation ready uptime was missing" >&2; exit 1 ;; esac
        \\  if [ "$ready_uptime" -le 0 ] || [ "$ready_uptime" -gt "$ready_budget_ns" ]; then echo "gpu-dashboard automation ready exceeded $ready_budget_ms ms: $ready_uptime ns" >&2; exit 1; fi
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'window @w1 "Native SDK GPU Dashboard"'*) ;; *) echo "gpu-dashboard window was missing from snapshot" >&2; exit 1 ;; esac
        \\  case "$snapshot" in *'view @w1/main kind=webview'*) echo "dashboard should not create an implicit main WebView" >&2; exit 1 ;; *) ;; esac
        \\  case "$snapshot" in *'source kind=html bytes=0'*) echo "dashboard should not publish an empty default WebView source" >&2; exit 1 ;; *) ;; esac
        \\  case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'accessibility_label="Native-rendered product dashboard canvas"'*) ;; *) echo "dashboard GPU canvas was missing from snapshot" >&2; exit 1 ;; esac
        \\  attempts=0
        \\  while [ "$attempts" -lt 50 ]; do
        \\    snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\    case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'gpu_nonblank=true'*'canvas_commands=67'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) break ;; esac
        \\    attempts=$((attempts + 1))
        \\    sleep 0.1
        \\  done
        \\  case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'gpu_nonblank=true'*'canvas_commands=67'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "dashboard GPU canvas did not present the retained display list as a packet" >&2; exit 1 ;; esac
        \\  case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'canvas_commands=67'*'widget_semantics=48'*) ;; *) echo "dashboard GPU canvas was missing retained commands or widget semantics" >&2; exit 1 ;; esac
        \\  first_frame_latency="$(printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/dashboard-canvas kind=gpu_surface.* gpu_first_frame_latency_ns=\([0-9][0-9]*\).*/\1/p')"
        \\  case "$first_frame_latency" in ''|*[!0-9]*) echo "dashboard GPU first frame latency was missing" >&2; exit 1 ;; esac
        \\  if [ "$first_frame_latency" -le 0 ]; then echo "dashboard GPU first frame latency was not recorded" >&2; exit 1; fi
        \\}
        \\launch_and_measure_first_frame
        \\if [ "$first_frame_latency" -gt "$smoke_budget_ns" ]; then
        \\  echo "dashboard GPU first frame exceeded $smoke_budget_ms ms ($first_frame_latency ns); relaunching once to rule out machine load" >&2
        \\  stop_app
        \\  launch_and_measure_first_frame
        \\fi
        \\if [ "$first_frame_latency" -gt "$smoke_budget_ns" ]; then echo "dashboard GPU first frame exceeded $smoke_budget_ms ms on both launches: $first_frame_latency ns" >&2; exit 1; fi
        \\# The runtime publishes its own fixed 150 ms budget verdict. Within that
        \\# budget the verdict must agree exactly; beyond it (reachable only when
        \\# NATIVE_SDK_SMOKE_BUDGET_MS > 150) the runtime must report the overrun honestly.
        \\if [ "$first_frame_latency" -le 150000000 ]; then
        \\  case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'gpu_first_frame_latency_budget_ns=150000000'*'gpu_first_frame_latency_budget_exceeded=0'*'gpu_first_frame_latency_budget_ok=true'*) ;; *) echo "dashboard GPU first frame exceeded the latency budget" >&2; exit 1 ;; esac
        \\else
        \\  case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'gpu_first_frame_latency_budget_ns=150000000'*'gpu_first_frame_latency_budget_ok=false'*) ;; *) echo "dashboard runtime did not report the first-frame budget overrun" >&2; exit 1 ;; esac
        \\fi
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'role=text name="Canvas frame:'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\widget_line() {
        \\  printf '%s\n' "$snapshot" | grep -F "$1" | head -1
        \\}
        \\line="$(widget_line 'role=tab name="Dashboard mode"')"
        \\case "$line" in *'actions=[focus,press,select]'*) ;; *) echo "dashboard toolbar mode semantics were missing" >&2; exit 1 ;; esac
        \\line="$(widget_line 'role=button name="Refresh dashboard"')"
        \\case "$line" in *'actions=[focus,press]'*) ;; *) echo "dashboard toolbar refresh semantics were missing" >&2; exit 1 ;; esac
        \\# CoreText-backed layout metrics: the refresh button must be sized by the
        \\# platform text measure provider, not the deterministic estimator
        \\# (estimateTextWidthForFont sizes "Refresh" at 14px to 51.842 -> 75.841995 wide).
        \\case "$line" in *'75.841995x34'*) echo "dashboard refresh button was sized by the estimator; platform text measurement is inactive" >&2; exit 1 ;; esac
        \\refresh_width="$(printf '%s\n' "$line" | sed -n 's/.*bounds=([0-9.,-]* \([0-9.]*\)x[0-9.]*).*/\1/p')"
        \\case "$refresh_width" in ''|*[!0-9.]*) echo "dashboard refresh button width was missing" >&2; exit 1 ;; esac
        \\if [ "$(printf '%s\n' "$refresh_width < 50 || $refresh_width > 110" | bc)" -eq 1 ]; then echo "dashboard refresh button width was implausible: $refresh_width" >&2; exit 1; fi
        \\line="$(widget_line 'role=button name="Live render status"')"
        \\case "$line" in *'actions=[focus,press]'*) ;; *) echo "dashboard live render button semantics were missing" >&2; exit 1 ;; esac
        \\line="$(widget_line 'role=textbox name="Forecast amount"')"
        \\case "$line" in *'text="$13.4M"'*) ;; *) echo "dashboard forecast textbox semantics were missing" >&2; exit 1 ;; esac
        \\line="$(widget_line 'role=dialog name="Revenue filter popover"')"
        \\case "$line" in '') echo "dashboard popover semantics were missing" >&2; exit 1 ;; esac
        \\line="$(widget_line 'role=text name="Canvas frame:')"
        \\case "$line" in *'packet ok'*) ;; *) echo "dashboard canvas status semantics were missing" >&2; exit 1 ;; esac
        \\gpu_frame_from_snapshot() {
        \\  printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/dashboard-canvas kind=gpu_surface.* gpu_frame=\([0-9][0-9]*\).*/\1/p'
        \\}
        \\canvas_revision_from_snapshot() {
        \\  printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/dashboard-canvas kind=gpu_surface.* canvas_revision=\([0-9][0-9]*\).*/\1/p'
        \\}
        \\snapshot_contains() {
        \\  case "$snapshot" in *"$1"*) return 0 ;; *) return 1 ;; esac
        \\}
        \\canvas_revision_before_resize="$(canvas_revision_from_snapshot)"
        \\case "$canvas_revision_before_resize" in ''|*[!0-9]*) echo "dashboard canvas revision was missing before resize" >&2; exit 1 ;; esac
        \\"$cli" automate resize 1120 700 >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'window @w1 "Native SDK GPU Dashboard" bounds=('*' 1120x700)'*'view @w1/dashboard-canvas kind=gpu_surface'*'bounds=(0,0 1120x700)'*'gpu_nonblank=true'*'canvas_commands=67'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'window @w1 "Native SDK GPU Dashboard" bounds=('*' 1120x700)'*) ;; *) echo "dashboard window resize was not reflected in snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'bounds=(0,0 1120x700)'*) ;; *) echo "dashboard GPU canvas did not relayout after resize" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'gpu_nonblank=true'*'canvas_commands=67'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "dashboard GPU canvas did not remain packet-renderable after resize" >&2; exit 1 ;; esac
        \\canvas_revision_after_resize="$(canvas_revision_from_snapshot)"
        \\case "$canvas_revision_after_resize" in ''|*[!0-9]*) echo "dashboard canvas revision was missing after resize" >&2; exit 1 ;; esac
        \\if [ "$canvas_revision_after_resize" -lt "$canvas_revision_before_resize" ]; then echo "dashboard canvas revision went backwards after resize: $canvas_revision_before_resize -> $canvas_revision_after_resize" >&2; exit 1; fi
        \\gpu_frame_before="$(gpu_frame_from_snapshot)"
        \\case "$gpu_frame_before" in ''|*[!0-9]*) gpu_frame_before=0 ;; esac
        \\gpu_frame_after="$gpu_frame_before"
        \\switch_id="$(printf '%s\n' "$snapshot" | sed -n 's/.*widget @w1\/dashboard-canvas#\([0-9][0-9]*\) role=switch name="Auto refresh".*/\1/p' | head -1)"
        \\case "$switch_id" in ''|*[!0-9]*) echo "dashboard auto refresh switch id was missing from snapshot" >&2; exit 1 ;; esac
        \\"$cli" automate widget-click dashboard-canvas "$switch_id" >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  gpu_frame_after="$(gpu_frame_from_snapshot)"
        \\  case "$gpu_frame_after" in ''|*[!0-9]*) gpu_frame_after=0 ;; esac
        \\  if [ "$gpu_frame_after" -gt "$gpu_frame_before" ]; then
        \\    if snapshot_contains 'Auto refresh off.' && snapshot_contains 'view @w1/dashboard-canvas kind=gpu_surface' && snapshot_contains 'canvas_frame_full_repaint=false' && snapshot_contains 'canvas_frame_pipeline_uploads=0' && snapshot_contains 'canvas_frame_glyph_uploads=0' && snapshot_contains 'canvas_frame_text_uploads=0' && snapshot_contains 'canvas_frame_gpu_packet_unsupported=0' && snapshot_contains 'canvas_frame_gpu_packet_representable=true'; then
        \\      switch_line="$(printf '%s\n' "$snapshot" | grep -F 'role=switch name="Auto refresh"' | head -1)"
        \\      case "$switch_line" in *'value=0'*) break ;; esac
        \\    fi
        \\  fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if [ "$gpu_frame_after" -le "$gpu_frame_before" ]; then echo "dashboard switch click did not request a GPU frame" >&2; exit 1; fi
        \\case "$snapshot" in *'Auto refresh off.'*) ;; *) echo "dashboard switch click did not update status" >&2; exit 1 ;; esac
        \\switch_line="$(printf '%s\n' "$snapshot" | grep -F 'role=switch name="Auto refresh"' | head -1)"
        \\case "$switch_line" in *'value=0'*) ;; *) echo "dashboard switch click did not route through pointer input" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "dashboard switch click did not present an incremental GPU packet without interaction-time uploads" >&2; exit 1 ;; esac
        \\input_timestamp="$(printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/dashboard-canvas kind=gpu_surface.* gpu_input_timestamp_ns=\([0-9][0-9]*\).*/\1/p')"
        \\case "$input_timestamp" in ''|*[!0-9]*) echo "dashboard GPU input timestamp was missing after widget interaction" >&2; exit 1 ;; esac
        \\if [ "$input_timestamp" -le 0 ]; then echo "dashboard GPU input timestamp was not recorded" >&2; exit 1; fi
        \\input_latency="$(printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/dashboard-canvas kind=gpu_surface.* gpu_input_latency_ns=\([0-9][0-9]*\).*/\1/p')"
        \\case "$input_latency" in ''|*[!0-9]*) echo "dashboard GPU input latency was missing after widget interaction" >&2; exit 1 ;; esac
        \\echo "gpu-dashboard smoke ok"
        ,
        "sh",
    });
    gpu_dashboard_smoke_run.addFileArg(cli_exe.getEmittedBin());
    gpu_dashboard_smoke_run.step.dependOn(&gpu_dashboard_smoke_build.step);
    gpu_dashboard_smoke_run.step.dependOn(&cli_exe.step);
    gpu_dashboard_smoke_step.dependOn(&gpu_dashboard_smoke_run.step);

    // Percentile performance check — a single-sample gate was noise-dominated,
    // so this asserts p90 over N launches. Deliberately NOT part of
    // `zig build test` or the fast gate tier: N launches are slow and the
    // numbers only mean something on a controlled machine. Runs via
    // `scripts/gate.sh full --perf` locally and a dedicated macos-14 CI job.
    // Knobs: NATIVE_SDK_PERF_LAUNCHES, NATIVE_SDK_PERF_INTERACTIONS, NATIVE_SDK_PERF_BUDGET_MS,
    // NATIVE_SDK_PERF_INPUT_BUDGET_MS — see scripts/perf-gpu-dashboard.sh.
    const gpu_dashboard_perf_step = b.step("test-gpu-dashboard-perf", "Run macOS GPU dashboard percentile performance check (N launches; slow)");
    const gpu_dashboard_perf_build = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true" });
    gpu_dashboard_perf_build.setCwd(b.path("examples/gpu-dashboard"));
    const gpu_dashboard_perf_run = b.addSystemCommand(&.{ "sh", "scripts/perf-gpu-dashboard.sh" });
    gpu_dashboard_perf_run.addFileArg(cli_exe.getEmittedBin());
    gpu_dashboard_perf_run.step.dependOn(&gpu_dashboard_perf_build.step);
    gpu_dashboard_perf_run.step.dependOn(&cli_exe.step);
    gpu_dashboard_perf_step.dependOn(&gpu_dashboard_perf_run.step);

    const canvas_preview_smoke_step = b.step("test-canvas-preview-smoke", "Run macOS canvas + webview (both-in-one-window) automation smoke test");
    const canvas_preview_smoke_build = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true" });
    canvas_preview_smoke_build.setCwd(b.path("examples/canvas-preview"));
    const canvas_preview_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/canvas-preview
        \\app="zig-out/bin/canvas-preview"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\automation_dir=".zig-cache/native-sdk-automation"
        \\mkdir -p "$automation_dir"
        \\rm -f "$automation_dir/snapshot.txt" "$automation_dir/accessibility.txt" "$automation_dir/windows.txt" "$automation_dir/command.txt" "$automation_dir/screenshot-preview-canvas.png"
        \\"$app" > .zig-cache/native-sdk-canvas-preview-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-canvas-preview-smoke.log) ----" >&2; cat .zig-cache/native-sdk-canvas-preview-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\ready="$("$cli" automate wait 2>&1)"
        \\case "$ready" in *"ready=true"*) ;; *) echo "canvas-preview automation snapshot was not ready" >&2; exit 1 ;; esac
        \\# Both architectures live in window 1: a presenting Metal canvas and
        \\# a live WKWebView on a real https URL — with no implicit main webview.
        \\"$cli" automate assert 'view @w1/preview-canvas kind=gpu_surface.*gpu_nonblank=true' 'view @w1/preview kind=webview.*url="https://example.com/"'
        \\"$cli" automate assert --absent 'view @w1/main kind=webview' 'source kind=html bytes=0'
        \\# The webview pane is snapped to the canvas anchor widget: right of
        \\# the 224pt sidebar, below the 56pt toolbar.
        \\preview_line="$(grep 'view @w1/preview kind=webview' "$automation_dir/snapshot.txt" | head -1)"
        \\preview_x="$(printf '%s\n' "$preview_line" | sed -n 's/.*bounds=(\([0-9.]*\),.*/\1/p')"
        \\case "$preview_x" in ''|*[!0-9.]*) echo "canvas-preview webview x was missing" >&2; exit 1 ;; esac
        \\if [ "$(printf '%s\n' "$preview_x < 224" | bc)" -eq 1 ]; then echo "canvas-preview webview was not snapped right of the sidebar: x=$preview_x" >&2; exit 1; fi
        \\# Navigation from a Msg: the app command switches the model URL and
        \\# the runtime navigates the platform webview.
        \\"$cli" automate native-command app.docs >/dev/null 2>&1
        \\"$cli" automate assert 'view @w1/preview kind=webview.*url="https://zero-native.dev/"' 'name="URL: https://zero-native.dev/"'
        \\# Resize keeps the pane snapped to the anchor widget's new frame:
        \\# the panel right of the 224pt sidebar and below the 56pt toolbar.
        \\"$cli" automate resize 1200 800 >/dev/null 2>&1
        \\"$cli" automate assert 'window @w1 "Native SDK Canvas Preview" bounds=.*1200x800' 'view @w1/preview kind=webview.*bounds=.224,56 976x744'
        \\# Canvas screenshot evidence (reference-rendered PNG of the chrome).
        \\"$cli" automate screenshot preview-canvas >/dev/null 2>&1
        \\test -s "$automation_dir/screenshot-preview-canvas.png" || { echo "canvas-preview screenshot was empty" >&2; exit 1; }
        \\echo "canvas-preview smoke ok"
        ,
        "sh",
    });
    canvas_preview_smoke_run.addFileArg(cli_exe.getEmittedBin());
    canvas_preview_smoke_run.step.dependOn(&canvas_preview_smoke_build.step);
    canvas_preview_smoke_run.step.dependOn(&cli_exe.step);
    canvas_preview_smoke_step.dependOn(&canvas_preview_smoke_run.step);

    const gpu_components_smoke_step = b.step("test-gpu-components-smoke", "Run macOS GPU components automation smoke test");
    const gpu_components_smoke_build = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true" });
    gpu_components_smoke_build.setCwd(b.path("examples/gpu-components"));
    const gpu_components_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/gpu-components
        \\app="zig-out/bin/gpu-components"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\automation_dir=".zig-cache/native-sdk-automation"
        \\mkdir -p "$automation_dir"
        \\# Startup latencies are load-sensitive on shared CI/agent machines.
        \\# NATIVE_SDK_SMOKE_BUDGET_MS raises the first-frame latency budget (default
        \\# stays 150 ms) and the automation-ready ceiling (default stays
        \\# 500 ms; the ceiling never drops below it) without weakening the
        \\# local defaults; every correctness assertion stays strict.
        \\smoke_budget_ms="${NATIVE_SDK_SMOKE_BUDGET_MS:-150}"
        \\case "$smoke_budget_ms" in ''|*[!0-9]*) echo "NATIVE_SDK_SMOKE_BUDGET_MS must be a positive integer of milliseconds: $smoke_budget_ms" >&2; exit 1 ;; esac
        \\if [ "$smoke_budget_ms" -le 0 ]; then echo "NATIVE_SDK_SMOKE_BUDGET_MS must be a positive integer of milliseconds: $smoke_budget_ms" >&2; exit 1; fi
        \\smoke_budget_ns=$((smoke_budget_ms * 1000000))
        \\ready_budget_ms="$smoke_budget_ms"
        \\if [ "$ready_budget_ms" -lt 500 ]; then ready_budget_ms=500; fi
        \\ready_budget_ns=$((ready_budget_ms * 1000000))
        \\rm -f "$automation_dir/snapshot.txt" "$automation_dir/accessibility.txt" "$automation_dir/windows.txt" "$automation_dir/command.txt"
        \\"$app" > .zig-cache/native-sdk-gpu-components-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-gpu-components-smoke.log) ----" >&2; cat .zig-cache/native-sdk-gpu-components-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\ready="$("$cli" automate wait 2>&1)"
        \\case "$ready" in *"ready=true"*) ;; *) echo "gpu-components automation snapshot was not ready" >&2; exit 1 ;; esac
        \\ready_uptime="$(printf '%s\n' "$ready" | sed -n 's/.*runtime_uptime_ns=\([0-9][0-9]*\).*/\1/p')"
        \\case "$ready_uptime" in ''|*[!0-9]*) echo "gpu-components automation ready uptime was missing" >&2; exit 1 ;; esac
        \\if [ "$ready_uptime" -le 0 ] || [ "$ready_uptime" -gt "$ready_budget_ns" ]; then echo "gpu-components automation ready exceeded $ready_budget_ms ms: $ready_uptime ns" >&2; exit 1; fi
        \\snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\case "$snapshot" in *'window @w1 "Native SDK GPU Components"'*) ;; *) echo "gpu-components window was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/main kind=webview'*) echo "components should not create an implicit main WebView" >&2; exit 1 ;; *) ;; esac
        \\case "$snapshot" in *'source kind=html bytes=0'*) echo "components should not publish an empty default WebView source" >&2; exit 1 ;; *) ;; esac
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'gpu_nonblank=true'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'gpu_nonblank=true'*) ;; *) echo "components GPU surface was not ready and nonblank" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "components GPU frame was not packet-representable" >&2; exit 1 ;; esac
        \\first_frame_latency="$(printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/components-canvas kind=gpu_surface.* gpu_first_frame_latency_ns=\([0-9][0-9]*\).*/\1/p')"
        \\case "$first_frame_latency" in ''|*[!0-9]*) echo "components GPU first frame latency was missing" >&2; exit 1 ;; esac
        \\if [ "$first_frame_latency" -le 0 ] || [ "$first_frame_latency" -gt "$smoke_budget_ns" ]; then echo "components GPU first frame exceeded $smoke_budget_ms ms: $first_frame_latency ns" >&2; exit 1; fi
        \\# The runtime publishes its own fixed 150 ms budget verdict. Within that
        \\# budget the verdict must agree exactly; beyond it (reachable only when
        \\# NATIVE_SDK_SMOKE_BUDGET_MS > 150) the runtime must report the overrun honestly.
        \\if [ "$first_frame_latency" -le 150000000 ]; then
        \\  case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'gpu_first_frame_latency_budget_ns=150000000'*'gpu_first_frame_latency_budget_exceeded=0'*'gpu_first_frame_latency_budget_ok=true'*) ;; *) echo "components GPU first frame exceeded the latency budget" >&2; exit 1 ;; esac
        \\else
        \\  case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'gpu_first_frame_latency_budget_ns=150000000'*'gpu_first_frame_latency_budget_ok=false'*) ;; *) echo "components runtime did not report the first-frame budget overrun" >&2; exit 1 ;; esac
        \\fi
        \\gpu_frame_from_snapshot() {
        \\  printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/components-canvas kind=gpu_surface.* gpu_frame=\([0-9][0-9]*\).*/\1/p'
        \\}
        \\canvas_revision_from_snapshot() {
        \\  printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/components-canvas kind=gpu_surface.* canvas_revision=\([0-9][0-9]*\).*/\1/p'
        \\}
        \\snapshot_contains() {
        \\  case "$snapshot" in *"$1"*) return 0 ;; *) return 1 ;; esac
        \\}
        \\case "$snapshot" in *'widget @w1/components-canvas#113 role=checkbox'*'value=1'*'actions=[focus,toggle]'*) ;; *) echo "checkbox widget was not initially selected" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'widget @w1/components-canvas#114 role=switch'*'value=1'*'actions=[focus,toggle]'*) ;; *) echo "switch widget was not initially selected" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'widget @w1/components-canvas#116 role=progressbar'*'value=1'*) ;; *) echo "progress widget was missing from the initial snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'widget @w1/components-canvas#117 role=tab'*'value=1'*'actions=[focus,select]'*) ;; *) echo "small segmented control was not initially selected" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'widget @w1/components-canvas#119 role=tab'*'value=0'*'actions=[focus,select]'*) ;; *) echo "large segmented control was not initially available" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'widget @w1/components-canvas#142 role=menuitem'*'actions=[focus,press,select]'*) ;; *) echo "menu item widget was not initially actionable" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'widget @w1/components-canvas#82 role=tab'*'actions=[focus,press,select]'*) ;; *) echo "theme toolbar widget was not initially actionable" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'widget @w1/components-canvas#83 role=button'*'actions=[focus,press]'*) ;; *) echo "refresh toolbar widget was not initially actionable" >&2; exit 1 ;; esac
        \\gpu_frame_before="$(gpu_frame_from_snapshot)"
        \\case "$gpu_frame_before" in ''|*[!0-9]*) gpu_frame_before=0 ;; esac
        \\gpu_frame_after="$gpu_frame_before"
        \\canvas_revision_before="$(canvas_revision_from_snapshot)"
        \\case "$canvas_revision_before" in ''|*[!0-9]*) canvas_revision_before=0 ;; esac
        \\canvas_revision_after="$canvas_revision_before"
        \\"$cli" automate widget-click components-canvas 82 >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  gpu_frame_after="$(gpu_frame_from_snapshot)"
        \\  case "$gpu_frame_after" in ''|*[!0-9]*) gpu_frame_after=0 ;; esac
        \\  canvas_revision_after="$(canvas_revision_from_snapshot)"
        \\  case "$canvas_revision_after" in ''|*[!0-9]*) canvas_revision_after=0 ;; esac
        \\  if [ "$gpu_frame_after" -gt "$gpu_frame_before" ] || [ "$canvas_revision_after" -gt "$canvas_revision_before" ]; then
        \\    if snapshot_contains 'GPU component theme: ' && snapshot_contains ' from native_view. Count 1.' && snapshot_contains 'view @w1/components-canvas kind=gpu_surface' && snapshot_contains 'canvas_frame_gpu_packet_unsupported=0' && snapshot_contains 'canvas_frame_gpu_packet_representable=true'; then break; fi
        \\  fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if [ "$gpu_frame_after" -le "$gpu_frame_before" ] && [ "$canvas_revision_after" -le "$canvas_revision_before" ]; then echo "theme automation command did not update the retained GPU canvas" >&2; exit 1; fi
        \\case "$snapshot" in *'GPU component theme: '*' from native_view. Count 1.'*) ;; *) echo "theme automation command did not update status" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "theme automation command did not present a packet-renderable GPU frame" >&2; exit 1 ;; esac
        \\"$cli" automate widget-action components-canvas 111 focus >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'widget @w1/components-canvas#111 role=textbox'*'focused=true'*'text="native-sdk"'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'widget @w1/components-canvas#111 role=textbox'*'focused=true'*'text="native-sdk"'*) ;; *) echo "widget focus automation did not focus retained text" >&2; exit 1 ;; esac
        \\"$cli" automate widget-key components-canvas z z >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'widget @w1/components-canvas#111 role=textbox'*'focused=true'*'text="native-sdkz"'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'widget @w1/components-canvas#111 role=textbox'*'focused=true'*'text="native-sdkz"'*) ;; *) echo "widget keyboard automation did not update retained text" >&2; exit 1 ;; esac
        \\"$cli" automate widget-key components-canvas tab >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'widget @w1/components-canvas#112 role=textbox'*'focused=true'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'widget @w1/components-canvas#112 role=textbox'*'focused=true'*) ;; *) echo "widget keyboard automation did not move focus" >&2; exit 1 ;; esac
        \\"$cli" automate widget-action components-canvas 105 press >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  if snapshot_contains 'Keyed icon_button #105.' && snapshot_contains 'widget @w1/components-canvas#105 role=button' && snapshot_contains 'actions=[focus,press]'; then break; fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if ! snapshot_contains 'Keyed icon_button #105.' || ! snapshot_contains 'widget @w1/components-canvas#105 role=button' || ! snapshot_contains 'actions=[focus,press]'; then echo "icon button automation press did not update status" >&2; exit 1; fi
        \\"$cli" automate widget-action components-canvas 111 set-text native-engine >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'widget @w1/components-canvas#111 role=textbox'*'text="native-engine"'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'widget @w1/components-canvas#111 role=textbox'*'text="native-engine"'*) ;; *) echo "text field automation did not update retained text" >&2; exit 1 ;; esac
        \\"$cli" automate widget-action components-canvas 115 increment >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'Keyed slider #115: value '*)
        \\    case "$snapshot" in *'widget @w1/components-canvas#115 role=slider'*'value=0.62'*) ;; *'widget @w1/components-canvas#115 role=slider'*) break ;; esac
        \\    ;;
        \\  esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'Keyed slider #115: value '*) ;; *) echo "slider automation increment did not update status" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'widget @w1/components-canvas#115 role=slider'*'value=0.62'*) echo "slider automation increment did not change value" >&2; exit 1 ;; *'widget @w1/components-canvas#115 role=slider'*) ;; *) echo "slider widget was missing after increment" >&2; exit 1 ;; esac
        \\gpu_frame_before="$(gpu_frame_from_snapshot)"
        \\case "$gpu_frame_before" in ''|*[!0-9]*) gpu_frame_before=0 ;; esac
        \\gpu_frame_after="$gpu_frame_before"
        \\"$cli" automate widget-drag components-canvas 115 0.25 0.82 >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  gpu_frame_after="$(gpu_frame_from_snapshot)"
        \\  case "$gpu_frame_after" in ''|*[!0-9]*) gpu_frame_after=0 ;; esac
        \\  if [ "$gpu_frame_after" -gt "$gpu_frame_before" ]; then
        \\    if snapshot_contains 'Clicked slider #115: value 0.82.' && snapshot_contains 'widget @w1/components-canvas#115 role=slider' && { snapshot_contains 'value=0.82' || snapshot_contains 'value=0.819'; }; then
        \\      case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) break ;; esac
        \\    fi
        \\  fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if [ "$gpu_frame_after" -le "$gpu_frame_before" ]; then echo "slider automation drag did not request a GPU frame" >&2; exit 1; fi
        \\if ! snapshot_contains 'Clicked slider #115: value 0.82.' || ! snapshot_contains 'widget @w1/components-canvas#115 role=slider' || { ! snapshot_contains 'value=0.82' && ! snapshot_contains 'value=0.819'; }; then echo "slider automation drag did not update retained slider state" >&2; exit 1; fi
        \\case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "slider automation drag did not present an incremental GPU packet without interaction-time uploads" >&2; exit 1 ;; esac
        \\"$cli" automate widget-action components-canvas 156 press >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  if snapshot_contains 'Keyed data_cell #156: selected.' && snapshot_contains 'widget @w1/components-canvas#156 role=gridcell' && snapshot_contains 'focused=true' && snapshot_contains 'value=1'; then break; fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if ! snapshot_contains 'Keyed data_cell #156: selected.' || ! snapshot_contains 'widget @w1/components-canvas#156 role=gridcell' || ! snapshot_contains 'focused=true' || ! snapshot_contains 'value=1'; then echo "grid cell automation press did not focus and report status" >&2; exit 1; fi
        \\gpu_frame_before="$(gpu_frame_from_snapshot)"
        \\case "$gpu_frame_before" in ''|*[!0-9]*) gpu_frame_before=0 ;; esac
        \\gpu_frame_after="$gpu_frame_before"
        \\"$cli" automate widget-click components-canvas 119 >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  gpu_frame_after="$(gpu_frame_from_snapshot)"
        \\  case "$gpu_frame_after" in ''|*[!0-9]*) gpu_frame_after=0 ;; esac
        \\  if [ "$gpu_frame_after" -gt "$gpu_frame_before" ]; then
        \\    if snapshot_contains 'Clicked segmented_control #119: selected.' && snapshot_contains 'widget @w1/components-canvas#117 role=tab' && snapshot_contains 'value=0' && snapshot_contains 'widget @w1/components-canvas#119 role=tab' && snapshot_contains 'focused=true' && snapshot_contains 'value=1'; then
        \\      case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) break ;; esac
        \\    fi
        \\  fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if [ "$gpu_frame_after" -le "$gpu_frame_before" ]; then echo "segmented control automation click did not request a GPU frame" >&2; exit 1; fi
        \\if ! snapshot_contains 'Clicked segmented_control #119: selected.' || ! snapshot_contains 'widget @w1/components-canvas#117 role=tab' || ! snapshot_contains 'value=0' || ! snapshot_contains 'widget @w1/components-canvas#119 role=tab' || ! snapshot_contains 'focused=true' || ! snapshot_contains 'value=1'; then echo "segmented control automation click did not update retained selection state" >&2; exit 1; fi
        \\case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "segmented control automation click did not present an incremental GPU packet without interaction-time uploads" >&2; exit 1 ;; esac
        \\gpu_frame_before="$(gpu_frame_from_snapshot)"
        \\case "$gpu_frame_before" in ''|*[!0-9]*) gpu_frame_before=0 ;; esac
        \\gpu_frame_after="$gpu_frame_before"
        \\"$cli" automate widget-action components-canvas 142 select >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  gpu_frame_after="$(gpu_frame_from_snapshot)"
        \\  case "$gpu_frame_after" in ''|*[!0-9]*) gpu_frame_after=0 ;; esac
        \\  if [ "$gpu_frame_after" -gt "$gpu_frame_before" ]; then
        \\    case "$snapshot" in *'widget @w1/components-canvas#142 role=menuitem'*'focused=true'*'value=1'*)
        \\      case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) break ;; esac
        \\      ;;
        \\    esac
        \\  fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if [ "$gpu_frame_after" -le "$gpu_frame_before" ]; then echo "menu item automation select did not request a GPU frame" >&2; exit 1; fi
        \\case "$snapshot" in *'widget @w1/components-canvas#142 role=menuitem'*'focused=true'*'value=1'*) ;; *) echo "menu item automation select did not update retained selection state" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "menu item automation select did not present an incremental GPU packet without interaction-time uploads" >&2; exit 1 ;; esac
        \\"$cli" automate widget-action components-canvas 113 toggle >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  if snapshot_contains 'Keyed checkbox #113: off.' && snapshot_contains 'widget @w1/components-canvas#113 role=checkbox' && snapshot_contains 'value=0'; then break; fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if ! snapshot_contains 'Keyed checkbox #113: off.' || ! snapshot_contains 'widget @w1/components-canvas#113 role=checkbox' || ! snapshot_contains 'value=0'; then echo "checkbox automation toggle did not update the retained widget snapshot" >&2; exit 1; fi
        \\gpu_frame_before="$(gpu_frame_from_snapshot)"
        \\case "$gpu_frame_before" in ''|*[!0-9]*) gpu_frame_before=0 ;; esac
        \\gpu_frame_after="$gpu_frame_before"
        \\"$cli" automate widget-click components-canvas 113 >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  gpu_frame_after="$(gpu_frame_from_snapshot)"
        \\  case "$gpu_frame_after" in ''|*[!0-9]*) gpu_frame_after=0 ;; esac
        \\  if [ "$gpu_frame_after" -gt "$gpu_frame_before" ]; then
        \\    if snapshot_contains 'Clicked checkbox #113: on.' && snapshot_contains 'widget @w1/components-canvas#113 role=checkbox' && snapshot_contains 'value=1'; then
        \\      case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) break ;; esac
        \\    fi
        \\  fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if [ "$gpu_frame_after" -le "$gpu_frame_before" ]; then echo "checkbox automation click did not request a GPU frame" >&2; exit 1; fi
        \\if ! snapshot_contains 'Clicked checkbox #113: on.' || ! snapshot_contains 'widget @w1/components-canvas#113 role=checkbox' || ! snapshot_contains 'value=1'; then echo "checkbox automation click did not route through pointer input" >&2; exit 1; fi
        \\case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "checkbox automation click did not present an incremental GPU packet without interaction-time uploads" >&2; exit 1 ;; esac
        \\"$cli" automate widget-action components-canvas 114 toggle >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  if snapshot_contains 'Keyed switch_control #114: off.' && snapshot_contains 'widget @w1/components-canvas#114 role=switch' && snapshot_contains 'value=0'; then break; fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if ! snapshot_contains 'Keyed switch_control #114: off.' || ! snapshot_contains 'widget @w1/components-canvas#114 role=switch' || ! snapshot_contains 'value=0'; then echo "switch automation toggle did not wake the idle app" >&2; exit 1; fi
        \\gpu_frame_before="$(gpu_frame_from_snapshot)"
        \\case "$gpu_frame_before" in ''|*[!0-9]*) gpu_frame_before=0 ;; esac
        \\gpu_frame_after="$gpu_frame_before"
        \\"$cli" automate widget-click components-canvas 114 >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  gpu_frame_after="$(gpu_frame_from_snapshot)"
        \\  case "$gpu_frame_after" in ''|*[!0-9]*) gpu_frame_after=0 ;; esac
        \\  if [ "$gpu_frame_after" -gt "$gpu_frame_before" ]; then
        \\    if snapshot_contains 'Clicked switch_control #114: on.' && snapshot_contains 'widget @w1/components-canvas#114 role=switch' && snapshot_contains 'value=1'; then
        \\      case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) break ;; esac
        \\    fi
        \\  fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if [ "$gpu_frame_after" -le "$gpu_frame_before" ]; then echo "switch automation click did not request a GPU frame" >&2; exit 1; fi
        \\if ! snapshot_contains 'Clicked switch_control #114: on.' || ! snapshot_contains 'widget @w1/components-canvas#114 role=switch' || ! snapshot_contains 'value=1'; then echo "switch automation click did not route through pointer input" >&2; exit 1; fi
        \\case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "switch automation click did not present an incremental GPU packet without interaction-time uploads" >&2; exit 1 ;; esac
        \\gpu_frame_before="$(gpu_frame_from_snapshot)"
        \\case "$gpu_frame_before" in ''|*[!0-9]*) gpu_frame_before=0 ;; esac
        \\gpu_frame_after="$gpu_frame_before"
        \\canvas_revision_before="$(canvas_revision_from_snapshot)"
        \\case "$canvas_revision_before" in ''|*[!0-9]*) canvas_revision_before=0 ;; esac
        \\canvas_revision_after="$canvas_revision_before"
        \\"$cli" automate widget-action components-canvas 120 increment >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  gpu_frame_after="$(gpu_frame_from_snapshot)"
        \\  case "$gpu_frame_after" in ''|*[!0-9]*) gpu_frame_after=0 ;; esac
        \\  canvas_revision_after="$(canvas_revision_from_snapshot)"
        \\  case "$canvas_revision_after" in ''|*[!0-9]*) canvas_revision_after=0 ;; esac
        \\  if [ "$gpu_frame_after" -gt "$gpu_frame_before" ] || [ "$canvas_revision_after" -gt "$canvas_revision_before" ]; then
        \\    if snapshot_contains 'Keyed list #120: offset 56.' && snapshot_contains 'widget @w1/components-canvas#120 role=list' && snapshot_contains 'scroll=[offset=56,viewport=56,content=168]'; then
        \\      case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) break ;; esac
        \\    fi
        \\  fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if [ "$gpu_frame_after" -le "$gpu_frame_before" ] && [ "$canvas_revision_after" -le "$canvas_revision_before" ]; then echo "list automation increment did not update the retained GPU canvas" >&2; exit 1; fi
        \\if ! snapshot_contains 'Keyed list #120: offset 56.' || ! snapshot_contains 'widget @w1/components-canvas#120 role=list' || ! snapshot_contains 'scroll=[offset=56,viewport=56,content=168]'; then echo "list automation increment did not update retained scroll semantics" >&2; exit 1; fi
        \\case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "list automation increment did not present an incremental GPU packet without interaction-time uploads" >&2; exit 1 ;; esac
        \\gpu_frame_before="$(gpu_frame_from_snapshot)"
        \\case "$gpu_frame_before" in ''|*[!0-9]*) gpu_frame_before=0 ;; esac
        \\gpu_frame_after="$gpu_frame_before"
        \\canvas_revision_before="$(canvas_revision_from_snapshot)"
        \\case "$canvas_revision_before" in ''|*[!0-9]*) canvas_revision_before=0 ;; esac
        \\canvas_revision_after="$canvas_revision_before"
        \\"$cli" automate widget-action components-canvas 150 increment >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  gpu_frame_after="$(gpu_frame_from_snapshot)"
        \\  case "$gpu_frame_after" in ''|*[!0-9]*) gpu_frame_after=0 ;; esac
        \\  canvas_revision_after="$(canvas_revision_from_snapshot)"
        \\  case "$canvas_revision_after" in ''|*[!0-9]*) canvas_revision_after=0 ;; esac
        \\  if [ "$gpu_frame_after" -gt "$gpu_frame_before" ] || [ "$canvas_revision_after" -gt "$canvas_revision_before" ]; then
        \\    if snapshot_contains 'Keyed table #150: offset 56.' && snapshot_contains 'widget @w1/components-canvas#150 role=grid' && snapshot_contains 'scroll=[offset=56,viewport=28,content=140]'; then
        \\      case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) break ;; esac
        \\    fi
        \\  fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if [ "$gpu_frame_after" -le "$gpu_frame_before" ] && [ "$canvas_revision_after" -le "$canvas_revision_before" ]; then echo "data grid automation increment did not update the retained GPU canvas" >&2; exit 1; fi
        \\if ! snapshot_contains 'Keyed table #150: offset 56.' || ! snapshot_contains 'widget @w1/components-canvas#150 role=grid' || ! snapshot_contains 'scroll=[offset=56,viewport=28,content=140]'; then echo "data grid automation increment did not update retained scroll semantics" >&2; exit 1; fi
        \\case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "data grid automation increment did not present an incremental GPU packet without interaction-time uploads" >&2; exit 1 ;; esac
        \\gpu_frame_before="$(gpu_frame_from_snapshot)"
        \\case "$gpu_frame_before" in ''|*[!0-9]*) gpu_frame_before=0 ;; esac
        \\gpu_frame_after="$gpu_frame_before"
        \\canvas_revision_before="$(canvas_revision_from_snapshot)"
        \\case "$canvas_revision_before" in ''|*[!0-9]*) canvas_revision_before=0 ;; esac
        \\canvas_revision_after="$canvas_revision_before"
        \\"$cli" automate widget-wheel components-canvas 130 20 >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  gpu_frame_after="$(gpu_frame_from_snapshot)"
        \\  case "$gpu_frame_after" in ''|*[!0-9]*) gpu_frame_after=0 ;; esac
        \\  canvas_revision_after="$(canvas_revision_from_snapshot)"
        \\  case "$canvas_revision_after" in ''|*[!0-9]*) canvas_revision_after=0 ;; esac
        \\  if [ "$gpu_frame_after" -gt "$gpu_frame_before" ] || [ "$canvas_revision_after" -gt "$canvas_revision_before" ]; then
        \\    case "$snapshot" in *'widget @w1/components-canvas#130 role=group'*'scroll=[offset=84,viewport=56,content=140]'*)
        \\      case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) break ;; esac
        \\      ;;
        \\    esac
        \\  fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if [ "$gpu_frame_after" -le "$gpu_frame_before" ] && [ "$canvas_revision_after" -le "$canvas_revision_before" ]; then echo "scroll automation wheel did not update the retained GPU canvas" >&2; exit 1; fi
        \\case "$snapshot" in *'widget @w1/components-canvas#130 role=group'*'scroll=[offset=84,viewport=56,content=140]'*) ;; *) echo "scroll automation wheel did not update retained scroll semantics" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_image_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "scroll automation wheel did not present an incremental GPU packet without interaction-time uploads" >&2; exit 1 ;; esac
        \\input_timestamp="$(printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/components-canvas kind=gpu_surface.* gpu_input_timestamp_ns=\([0-9][0-9]*\).*/\1/p')"
        \\case "$input_timestamp" in ''|*[!0-9]*) echo "components GPU input timestamp was missing after widget interaction" >&2; exit 1 ;; esac
        \\if [ "$input_timestamp" -le 0 ]; then echo "components GPU input timestamp was not recorded" >&2; exit 1; fi
        \\input_latency="$(printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/components-canvas kind=gpu_surface.* gpu_input_latency_ns=\([0-9][0-9]*\).*/\1/p')"
        \\case "$input_latency" in ''|*[!0-9]*) echo "components GPU input latency was missing after widget interaction" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'gpu_input_latency_budget_exceeded=0'*'gpu_input_latency_budget_ok=true'*) ;; *) echo "components GPU input latency exceeded the frame budget" >&2; exit 1 ;; esac
        \\echo "gpu-components smoke ok"
        ,
        "sh",
    });
    gpu_components_smoke_run.addFileArg(cli_exe.getEmittedBin());
    gpu_components_smoke_run.step.dependOn(&gpu_components_smoke_build.step);
    gpu_components_smoke_run.step.dependOn(&cli_exe.step);
    gpu_components_smoke_step.dependOn(&gpu_components_smoke_run.step);

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
        \\response_file=".zig-cache/native-sdk-automation/bridge-response.txt"
        \\mkdir -p .zig-cache/native-sdk-automation
        \\rm -f .zig-cache/native-sdk-automation/snapshot.txt .zig-cache/native-sdk-automation/windows.txt .zig-cache/native-sdk-automation/command.txt "$response_file"
        \\printf 'bridge %s\n' "$request" > .zig-cache/native-sdk-automation/command.txt
        \\"$app" > .zig-cache/native-sdk-webview-cef-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-webview-cef-smoke.log) ----" >&2; cat .zig-cache/native-sdk-webview-cef-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\snapshot="$("$cli" automate wait 2>&1)"
        \\case "$snapshot" in *"ready=true"*) ;; *) echo "automation snapshot was not ready" >&2; exit 1 ;; esac
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*'pong from Zig'*) ;; *) echo "native.ping response was unexpected: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-create","command":"native-sdk.webview.create","payload":{"label":"smoke","url":"https://example.com","frame":{"x":24,"y":24,"width":320,"height":220}}}' > .zig-cache/native-sdk-automation/command.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "cef webview create did not succeed: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-resize","command":"native-sdk.webview.setFrame","payload":{"label":"smoke","frame":{"x":36,"y":36,"width":420,"height":260}}}' > .zig-cache/native-sdk-automation/command.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "cef webview resize did not succeed: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-navigate","command":"native-sdk.webview.navigate","payload":{"label":"smoke","url":"https://example.com/?smoke=1"}}' > .zig-cache/native-sdk-automation/command.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "cef webview navigate did not succeed: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-close","command":"native-sdk.webview.close","payload":{"label":"smoke"}}' > .zig-cache/native-sdk-automation/command.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "cef webview close did not succeed: $response" >&2; exit 1 ;; esac
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

    const lib_step = b.step("lib", "Build native-sdk embeddable static library");
    lib_step.dependOn(&b.addInstallArtifact(embed_lib, .{}).step);

    const doctor_run = b.addRunArtifact(host_cli_exe);
    doctor_run.addArg("doctor");
    const doctor_step = b.step("doctor", "Print native-sdk platform diagnostics");
    doctor_step.dependOn(&doctor_run.step);

    const validate_run = b.addRunArtifact(host_cli_exe);
    validate_run.addArgs(&.{ "validate", "app.zon" });
    const validate_step = b.step("validate", "Validate app.zon");
    validate_step.dependOn(&validate_run.step);

    const bundle_run = b.addRunArtifact(host_cli_exe);
    bundle_run.addArgs(&.{ "bundle-assets", "app.zon", "assets", "zig-out/assets" });
    const bundle_step = b.step("bundle-assets", "Bundle app assets");
    bundle_step.dependOn(&bundle_run.step);

    const package_run = b.addRunArtifact(host_cli_exe);
    package_run.addArgs(&.{
        "package",
        "--target",
        @tagName(package_target),
        "--output",
        b.fmt("zig-out/package/native-sdk-{s}-{s}-{s}{s}", .{ package_version, @tagName(package_target), optimize_name, packageSuffix(package_target) }),
        "--binary",
    });
    package_run.addFileArg(embed_lib.getEmittedBin());
    package_run.addArgs(&.{ "--manifest", "app.zon", "--assets", "assets", "--optimize", optimize_name, "--signing", @tagName(signing_mode), "--web-engine", @tagName(web_engine), "--cef-dir", cef_dir });
    if (cef_auto_install) package_run.addArg("--cef-auto-install");
    package_run.step.dependOn(&embed_lib.step);
    package_run.step.dependOn(&bundle_run.step);
    const package_step = b.step("package", "Create local package artifact");
    package_step.dependOn(&package_run.step);

    const package_cef_run = b.addRunArtifact(host_cli_exe);
    package_cef_run.addArgs(&.{
        "package",
        "--target",
        "macos",
        "--output",
        b.fmt("zig-out/package/native-sdk-cef-smoke-{s}.app", .{optimize_name}),
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
            \\app="zig-out/package/native-sdk-cef-smoke-{s}.app"
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

    const package_windows_run = b.addRunArtifact(host_cli_exe);
    package_windows_run.addArgs(&.{ "package-windows", "--output", b.fmt("zig-out/package/native-sdk-{s}-windows-Debug", .{package_version}), "--manifest", "app.zon", "--assets", "assets" });
    const package_windows_step = b.step("package-windows", "Create local Windows artifact directory");
    package_windows_step.dependOn(&package_windows_run.step);

    const package_linux_run = b.addRunArtifact(host_cli_exe);
    package_linux_run.addArgs(&.{ "package-linux", "--output", b.fmt("zig-out/package/native-sdk-{s}-linux-Debug", .{package_version}), "--manifest", "app.zon", "--assets", "assets" });
    const package_linux_step = b.step("package-linux", "Create local Linux artifact directory");
    package_linux_step.dependOn(&package_linux_run.step);

    const package_ios_run = b.addRunArtifact(host_cli_exe);
    package_ios_run.addArgs(&.{ "package-ios", "--output", b.fmt("zig-out/mobile/native-sdk-{s}-ios-Debug", .{package_version}), "--manifest", "app.zon", "--assets", "assets" });
    const package_ios_step = b.step("package-ios", "Create local iOS host skeleton");
    package_ios_step.dependOn(&package_ios_run.step);

    const package_android_run = b.addRunArtifact(host_cli_exe);
    package_android_run.addArgs(&.{ "package-android", "--output", b.fmt("zig-out/mobile/native-sdk-{s}-android-Debug", .{package_version}), "--manifest", "app.zon", "--assets", "assets" });
    const package_android_step = b.step("package-android", "Create local Android host skeleton");
    package_android_step.dependOn(&package_android_run.step);

    // Default app icon: rendered from vector geometry (tools/
    // generate_app_icon.zig) through the SDK's own path rasterizer, so
    // the checked-in .icns/.ico/.png/.svg all regenerate from source.
    // `iconutil` assembles and round-trip-validates the .icns (macOS
    // only), and the CLI's embedded scaffold copy is kept in sync.
    const generate_icon_step = b.step("generate-icon", "Regenerate the default app icon (.icns/.ico/.png/.svg) from vector source");
    const generate_icon_mod = module(b, target, optimize, "tools/generate_app_icon.zig");
    generate_icon_mod.addImport("native_sdk", desktop_mod);
    const generate_icon_exe = b.addExecutable(.{
        .name = "generate-app-icon",
        .root_module = generate_icon_mod,
    });
    const generate_icon_run = b.addRunArtifact(generate_icon_exe);
    generate_icon_run.addArgs(&.{ "zig-out/icon.iconset", "assets/icon.png", "assets/icon.ico", "assets/icon.svg" });
    generate_icon_run.has_side_effects = true;
    const iconset_script = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\command -v iconutil >/dev/null || { echo "iconutil required (macOS) to assemble .icns" >&2; exit 1; }
        \\iconutil -c icns zig-out/icon.iconset -o assets/icon.icns
        \\cp assets/icon.icns src/tooling/default_icon.icns
        \\rm -rf zig-out/icon-roundtrip.iconset
        \\iconutil -c iconset assets/icon.icns -o zig-out/icon-roundtrip.iconset
        \\test -f zig-out/icon-roundtrip.iconset/icon_512x512@2x.png
        \\echo "generated assets/icon.{icns,ico,png,svg} and src/tooling/default_icon.icns"
    });
    iconset_script.step.dependOn(&generate_icon_run.step);
    generate_icon_step.dependOn(&iconset_script.step);

    const notarize_run = b.addRunArtifact(host_cli_exe);
    notarize_run.addArgs(&.{
        "package",
        "--target",
        "macos",
        "--output",
        b.fmt("zig-out/package/native-sdk-{s}-macos-{s}.app", .{ package_version, optimize_name }),
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
            \\APP="zig-out/package/native-sdk-{s}-macos-{s}.app"
            \\DMG="zig-out/package/native-sdk-{s}-macos-{s}.dmg"
            \\test -d "$APP" || {{ echo "run 'zig build package' first" >&2; exit 1; }}
            \\hdiutil create -volname "native-sdk" -srcfolder "$APP" -ov -format UDZO "$DMG"
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
        const cef_bundle_auto = b.addRunArtifact(host_cli_exe);
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

/// The short commit hash of the framework checkout the CLI is built
/// from, for `native version` staleness checks. "unknown" when
/// git is unavailable (e.g. building from a package tarball).
fn cliBuildCommit(b: *std.Build) []const u8 {
    var code: u8 = undefined;
    const output = b.runAllowFail(&.{ "git", "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return "unknown";
    const trimmed = std.mem.trim(u8, output, " \n\r\t");
    if (trimmed.len == 0) return "unknown";
    return trimmed;
}

fn testArtifact(b: *std.Build, mod: *std.Build.Module) *std.Build.Step.Compile {
    // use_llvm: Zig 0.16.0's self-hosted x86_64 backend miscompiles the
    // SysV C ABI for f32-heavy signatures (native_sdk_app_viewport); see
    // useLlvmWorkaround in build/app.zig for the full story and repro.
    const use_llvm = if (mod.resolved_target) |target| @import("build/app.zig").useLlvmWorkaround(target) else null;
    return b.addTest(.{ .root_module = mod, .use_llvm = use_llvm });
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

const FileContainsCheck = struct {
    path: []const u8,
    pattern: []const u8,
};

fn addFileContainsCheckStep(b: *std.Build, checker: *std.Build.Step.Compile, group: *std.Build.Step, name: []const u8, description: []const u8, checks: []const FileContainsCheck) void {
    const step = b.step(name, description);
    for (checks) |check_value| {
        const check = b.addRunArtifact(checker);
        check.addArg(check_value.path);
        check.addArg(check_value.pattern);
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
