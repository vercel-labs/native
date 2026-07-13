const std = @import("std");
const android_tool = @import("android.zig");
const app_icon_tool = @import("app_icon");
const assets_tool = @import("assets.zig");
const buildgraph = @import("buildgraph.zig");
const cef = @import("cef.zig");
const codesign = @import("codesign.zig");
const diagnostics = @import("diagnostics");
const ios_tool = @import("ios.zig");
const manifest_tool = @import("manifest.zig");
const web_engine_tool = @import("web_engine.zig");
const xcodeproj_tool = @import("xcodeproj.zig");

/// The SDK's default app icon (kept in sync by `zig build generate-icon`):
/// what a bundle ships when app.zon configures no usable icon at all, so
/// a fresh package is never a text placeholder pretending to be an icon.
const default_icon_icns = @embedFile("default_icon.icns");
/// The same default as a PNG source, for targets whose icons re-render
/// from a square source (the iOS asset catalog).
const default_icon_png = @embedFile("default_icon.png");

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
    /// The `--web-layer` flag, when the caller passed one: beats app.zon's
    /// `.webview_layer` the same way `-Dweb-layer` beats it in the build
    /// graph. The standard build graphs always pass their RESOLVED layer
    /// decision here (include|exclude), so a graph-driven package never
    /// re-infers what the graph already compiled into the exe. Null means
    /// the manifest field decides.
    web_layer_setting: ?manifest_tool.WebViewLayerSetting = null,
    cef_dir: []const u8 = web_engine_tool.default_cef_dir,
    signing: SigningConfig = .{},
    archive: bool = false,
    /// The process environment, when the caller has one (the CLI). The
    /// Android artifact probes it for the SDK/NDK toolchain to assemble
    /// the debug APK; without it the generated project is still complete
    /// and the assembly is skipped with a notice — which also keeps
    /// package unit tests hermetic.
    env_map: ?*std.process.Environ.Map = null,
};

pub const PackageStats = struct {
    path: []const u8,
    artifact_name: []const u8 = "",
    target: PackageTarget = .macos,
    signing_mode: SigningMode = .none,
    /// True when a signing mode that claims to sign (adhoc or identity)
    /// ran AND the result passed `codesign --verify --deep --strict`:
    /// the proof behind the report's "signed, verified" line. A package
    /// whose signing or verification fails never produces stats at all.
    signing_verified: bool = false,
    asset_count: usize = 0,
    web_engine: WebEngine = .system,
    web_layer: ?manifest_tool.WebLayer = null,
    archive_path: ?[]const u8 = null,
    /// True when a Windows package wrapped a CONSOLE-subsystem exe: the
    /// app will flash a terminal window behind itself on every launch.
    /// Release-shaped `native build` exes are GUI-subsystem, so this
    /// only fires for stale or hand-supplied binaries — the packager
    /// warns and the report carries the truth (pinned by tests over a
    /// synthetic PE header).
    windows_console_subsystem: bool = false,
};

/// The web-layer verdict for a package, from the same declare-to-use
/// inference the build graph runs — fed the RESOLVED engine
/// (`--web-engine` orelse app.zon, resolved by the CLI before packaging)
/// so a Chromium flag on a system manifest still ships the layer, and
/// the RESOLVED layer setting (`--web-layer` orelse app.zon) so a
/// flag-overridden exe is packaged under the decision it was built with.
/// Metadata that cannot be inferred (invalid or contradictory
/// `.webview_layer`) keeps the layer here — `createPackage` refuses
/// those loudly up front, and the direct artifact helpers must not
/// silently strip a layer on bad input.
fn webLayerFor(options: PackageOptions) manifest_tool.WebLayer {
    return manifest_tool.webLayerResolved(options.metadata, options.web_engine, options.web_layer_setting) catch .{ .enabled = true, .reason = .declared_include };
}

/// The verdict line's engine half: what web layer this artifact ships.
fn webLayerEngineName(layer: manifest_tool.WebLayer, target: PackageTarget, web_engine: WebEngine) []const u8 {
    if (!layer.enabled) return "none";
    if (web_engine == .chromium) return "chromium";
    return if (target == .windows) "webview2" else "system";
}

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
    // The package boundary of the reject-conflicts contract: an exclude
    // (from `--web-layer` or app.zon) against declared web content — or
    // against a resolved Chromium engine — never becomes an artifact.
    _ = manifest_tool.webLayerResolved(options.metadata, options.web_engine, options.web_layer_setting) catch |err| {
        switch (err) {
            error.WebViewLayerConflict => std.debug.print("error: {s}\n", .{if (options.web_layer_setting == .exclude) manifest_tool.web_layer_flag_conflict_message else manifest_tool.web_layer_conflict_message}),
            error.InvalidWebViewLayer => std.debug.print("error: app.zon webview_layer is invalid - expected \"auto\", \"include\", or \"exclude\"\n", .{}),
        }
        return err;
    };
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
    if (stats.web_layer) |layer| {
        std.debug.print("  web layer: {s} ({s})\n", .{ webLayerEngineName(layer, stats.target, stats.web_engine), layer.sourceText() });
    }
    if (stats.signing_verified) {
        std.debug.print("  signing: {s} (signed, verified)\n", .{@tagName(stats.signing_mode)});
    }
    if (stats.archive_path) |archive| {
        std.debug.print("  archive: {s}\n", .{archive});
    }
}

pub fn createLocalPackage(io: std.Io, output_path: []const u8) !PackageStats {
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.native_sdk.local",
        .name = "native-sdk-local",
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
    try writeFile(package_dir, io, "Contents/Resources/README.txt", "Unsigned local Native SDK macOS app bundle.\n");
    const assets_output = try macosAssetOutputPath(allocator, options);
    defer allocator.free(assets_output);
    const bundle_stats = try assets_tool.bundle(allocator, io, options.assets_dir, assets_output);
    try copyMacosIcon(allocator, io, package_dir, options);
    try copyMacosDocumentIcons(allocator, io, package_dir, options.metadata);
    try writeReport(allocator, package_dir, io, "Contents/Resources/package-manifest.zon", options, executable_name, bundle_stats.asset_count);
    if (options.web_engine == .chromium) {
        try cef.ensureLayout(io, options.cef_dir);
        try copyMacosCefRuntime(allocator, io, package_dir, options.cef_dir);
    }
    const signing_verified = try runSigning(allocator, io, package_dir, options);

    return .{
        .path = options.output_path,
        .artifact_name = std.fs.path.basename(options.output_path),
        .target = .macos,
        .signing_mode = options.signing.mode,
        .signing_verified = signing_verified,
        .asset_count = bundle_stats.asset_count,
        .web_engine = options.web_engine,
        .web_layer = webLayerFor(options),
    };
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

    // Native-only apps ship no WebView2 loader: their host was compiled
    // without the embedded web layer, so the loader would be dead bytes
    // pretending the app can spawn a webview.
    const wants_webview2_loader = options.target == .windows and options.web_engine == .system and webLayerFor(options).enabled;
    // The package-time half of the web-layer audit (the build-time half
    // is tools/audit_web_layer.zig): a Windows exe that references
    // WebView2Loader.dll was compiled WITH the embedded web layer, so
    // packaging it loaderless ships an app whose every webview call
    // fails at runtime. Refuse the mismatch and teach the fix — this
    // catches exes built under an override the packaging decision never
    // saw (a stale zig-out binary, a hand-supplied --binary).
    if (options.target == .windows and !wants_webview2_loader) {
        if (options.binary_path) |binary_path| {
            if (try peReferencesWebView2Loader(allocator, io, binary_path)) {
                std.debug.print("error: {s} references WebView2Loader.dll but this package ships no web layer, so its webviews would fail to spawn - the exe was built with the embedded web layer (for example `zig build -Dweb-layer=include`)\n" ++
                    "  package with `--web-layer include`, or rebuild the binary to match the packaging decision\n", .{binary_path});
                return error.WebViewLayerMismatch;
            }
        }
    }
    // The Linux twin of that guard (the build-time half is the ELF scan
    // in tools/audit_web_layer.zig): an executable that links WebKitGTK
    // was compiled WITH the embedded web layer, so packaging it under a
    // native-only decision ships an app that still demands libwebkitgtk
    // on every user machine while its webviews would fail to spawn.
    if (options.target == .linux and options.web_engine == .system and !webLayerFor(options).enabled) {
        if (options.binary_path) |binary_path| {
            if (try elfReferencesWebKitGtk(allocator, io, binary_path)) {
                std.debug.print("error: {s} references WebKitGTK but this package ships no web layer, so its webviews would fail to spawn - the binary was built with the embedded web layer (for example `zig build -Dweb-layer=include`)\n" ++
                    "  package with `--web-layer include`, or rebuild the binary to match the packaging decision\n", .{binary_path});
                return error.WebViewLayerMismatch;
            }
        }
    }
    // The subsystem posture check: `native build` produces GUI-subsystem
    // release exes on Windows, so a console-subsystem exe here is a stale
    // zig-out binary or a hand-supplied --binary — packaged as-is it
    // flashes a terminal window behind the app on every launch. Warn and
    // carry the truth in the stats/report; the package still builds
    // (the app works, it just looks unfinished).
    const windows_console_subsystem = options.target == .windows and
        if (options.binary_path) |binary_path| try peIsConsoleSubsystem(allocator, io, binary_path) else false;
    if (windows_console_subsystem) {
        std.debug.print("warning[package.console-subsystem]: {s} is a console-subsystem exe, so a terminal window will open behind the app on every launch\n" ++
            "  rebuild with `native build` (release exes are GUI-subsystem) or pass a GUI-subsystem --binary\n", .{options.binary_path.?});
    }
    if (options.binary_path) |binary_path| {
        const binary_subpath = try std.fmt.allocPrint(allocator, "bin/{s}", .{executable_name});
        defer allocator.free(binary_subpath);
        try copyFileToDir(allocator, io, dir, binary_path, binary_subpath);
        if (wants_webview2_loader) {
            try copyWindowsWebView2Loader(allocator, io, dir, options, binary_path);
        }
    } else if (wants_webview2_loader) {
        try writeFile(dir, io, "bin/README.txt", "Build the app binary separately and place it here for this target, together with the WebView2Loader.dll for its architecture (vendored in the SDK under third_party/webview2/).\n");
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
        try writeLinuxIcons(allocator, io, dir, options.metadata);
    } else if (options.target == .windows) {
        try writeWindowsIcon(allocator, io, dir, options.metadata);
        if (hasRegistrationMetadata(options.metadata)) {
            try dir.createDirPath(io, "install");
            const registry_script = try windowsRegistrationScript(allocator, options.metadata, executable_name);
            defer allocator.free(registry_script);
            try writeFile(dir, io, "install/register-file-types.ps1", registry_script);
        }
    }
    if (options.web_engine == .chromium) {
        const cef_platform = cefPlatformForTarget(options.target) orelse return error.UnsupportedWebEngine;
        try cef.ensureLayoutFor(io, cef_platform, options.cef_dir);
        try copyDesktopCefRuntime(allocator, io, dir, options.target, options.cef_dir);
    }
    try writeReport(allocator, dir, io, "package-manifest.zon", options, executable_name, bundle_stats.asset_count);
    return .{ .path = options.output_path, .artifact_name = std.fs.path.basename(options.output_path), .target = options.target, .asset_count = bundle_stats.asset_count, .web_engine = options.web_engine, .web_layer = webLayerFor(options), .windows_console_subsystem = windows_console_subsystem };
}

/// The iOS host tier: a COMPLETE Xcode project the user never edits —
/// the toolkit-owned UIKit host sources, the generated Info.plist and
/// asset catalog, the bundled app assets, and the embed static library,
/// tied together by a deterministic project file (xcodeproj.zig) so
/// `xcodebuild archive` works with zero edits. Everything app-specific
/// comes from app.zon. Code signing stays manual, like macOS
/// notarization.
fn createIosArtifact(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !PackageStats {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, options.output_path);
    var dir = try cwd.openDir(io, options.output_path, .{});
    defer dir.close(io);

    // iOS bundle identifiers allow only alphanumerics, hyphens, and
    // periods; underscores in app.zon ids normalize to hyphens (the
    // mirror of the Android hyphen-to-underscore mapping).
    const bundle_id = try ios_tool.bundleIdAlloc(allocator, options.metadata.id);
    defer allocator.free(bundle_id);
    const project = xcodeproj_tool.ProjectModel{
        .name = options.metadata.name,
        .bundle_id = bundle_id,
        .version = options.metadata.version,
    };

    // The project file and its shared scheme (headless xcodebuild needs
    // an on-disk scheme; Xcode only auto-creates them interactively).
    const project_dir = try std.fmt.allocPrint(allocator, "{s}.xcodeproj", .{options.metadata.name});
    defer allocator.free(project_dir);
    const schemes_dir = try std.fmt.allocPrint(allocator, "{s}/xcshareddata/xcschemes", .{project_dir});
    defer allocator.free(schemes_dir);
    try dir.createDirPath(io, schemes_dir);
    const pbxproj = try xcodeproj_tool.pbxprojAlloc(allocator, project);
    defer allocator.free(pbxproj);
    const pbxproj_path = try std.fmt.allocPrint(allocator, "{s}/project.pbxproj", .{project_dir});
    defer allocator.free(pbxproj_path);
    try writeFile(dir, io, pbxproj_path, pbxproj);
    const scheme = try xcodeproj_tool.schemeAlloc(allocator, project);
    defer allocator.free(scheme);
    const scheme_path = try std.fmt.allocPrint(allocator, "{s}/{s}.xcscheme", .{ schemes_dir, options.metadata.name });
    defer allocator.free(scheme_path);
    try writeFile(dir, io, scheme_path, scheme);

    // The toolkit host sources and the app.zon-derived Info.plist.
    try dir.createDirPath(io, "Host");
    try writeFile(dir, io, "Host/" ++ ios_tool.host_source_name, ios_tool.host_source);
    try writeFile(dir, io, "Host/" ++ ios_tool.host_header_name, ios_tool.host_header);
    const info_plist = try ios_tool.infoPlistAlloc(allocator, options.metadata);
    defer allocator.free(info_plist);
    try writeFile(dir, io, "Host/Info.plist", info_plist);

    // App icon (single-source pipeline) and bundled assets. The bundled
    // folder is named "Assets", NOT "Resources": a bundle-root directory
    // named Resources makes CFBundle read the .app as a deep
    // (macOS-layout) bundle, and xcodebuild's archive stamping then fails
    // to find the Info.plist ("Archive Missing Bundle Identifier").
    try writeIosIcon(allocator, io, dir, options.metadata);
    const assets_output = try assetOutputPath(allocator, options.output_path, "Assets", options);
    defer allocator.free(assets_output);
    const bundle_stats = try assets_tool.bundle(allocator, io, options.assets_dir, assets_output);

    // The app's embed static library (device arm64 slice — built by the
    // CLI before packaging, or passed via --binary).
    try dir.createDirPath(io, "Libraries");
    if (options.binary_path) |binary_path| try copyFileToDir(allocator, io, dir, binary_path, "Libraries/libnative-sdk.a");

    const readme = try iosProjectReadme(allocator, options.metadata);
    defer allocator.free(readme);
    try writeFile(dir, io, "README.md", readme);
    try writeReport(allocator, dir, io, "package-manifest.zon", options, "libnative-sdk.a", bundle_stats.asset_count);
    return .{ .path = options.output_path, .artifact_name = std.fs.path.basename(options.output_path), .target = .ios, .asset_count = bundle_stats.asset_count, .web_engine = options.web_engine, .web_layer = webLayerFor(options) };
}

fn iosProjectReadme(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\# {s} — iOS host project
        \\
        \\Generated by `native package --target ios`. Everything here is toolkit-owned output derived from app.zon — regenerate instead of editing.
        \\
        \\- `{s}.xcodeproj` — deterministic project with a shared scheme; `xcodebuild -scheme {s} archive` works with zero edits (for an unsigned verification pass add `CODE_SIGNING_ALLOWED=NO`).
        \\- `Host/` — the toolkit UIKit host (canvas presentation, touch/keyboard/IME, safe areas) and the generated Info.plist.
        \\- `Libraries/libnative-sdk.a` — the app compiled as the embed static library (device arm64 slice). The simulator loop is `native dev --target ios`, which rebuilds the library for the simulator.
        \\- `Assets.xcassets`, `Assets/` — the app icon rendered from the single-source icon pipeline, and the bundled app assets.
        \\
        \\Code signing stays manual, like macOS notarization: open the project once in Xcode to pick a team, or pass `DEVELOPMENT_TEAM=<id> CODE_SIGN_IDENTITY="Apple Development"` to xcodebuild.
        \\
    , .{ metadata.displayName(), metadata.name, metadata.name });
}

/// The Android host tier: a COMPLETE generated host project the user
/// never edits — the toolkit-owned host sources, the app.zon-derived
/// AndroidManifest.xml, launcher icons, the bundled app assets, and the
/// embed static library — plus the assembled debug APK when the Android
/// SDK/NDK toolchain is present. The APK assembles directly with the
/// SDK's build tools (aapt2/javac/d8/zipalign/apksigner; see
/// android.zig for the rationale). Store signing keys stay manual, like
/// macOS notarization.
fn createAndroidArtifact(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !PackageStats {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, options.output_path);
    var dir = try cwd.openDir(io, options.output_path, .{});
    defer dir.close(io);

    // The toolkit host sources and the app.zon-derived manifest.
    try dir.createDirPath(io, "Host");
    try writeFile(dir, io, "Host/" ++ android_tool.host_activity_name, android_tool.host_activity_source);
    try writeFile(dir, io, "Host/" ++ android_tool.host_bridge_name, android_tool.host_bridge_source);
    try writeFile(dir, io, "Host/" ++ android_tool.host_header_name, android_tool.host_header);
    const manifest = try android_tool.manifestAlloc(allocator, options.metadata, true);
    defer allocator.free(manifest);
    try writeFile(dir, io, "AndroidManifest.xml", manifest);

    // Launcher icons (single-source pipeline, default fallback so the
    // manifest's @mipmap reference always resolves) and bundled assets
    // in the layout the host mirrors onto the device at first launch.
    try writeAndroidIcons(allocator, io, dir, options.metadata);
    const res_path = try std.fs.path.join(allocator, &.{ options.output_path, "res" });
    defer allocator.free(res_path);
    try android_tool.writeHostResources(io, res_path);
    const assets_output = try assetOutputPath(allocator, options.output_path, "assets/native-sdk", options);
    defer allocator.free(assets_output);
    const bundle_stats = try assets_tool.bundle(allocator, io, options.assets_dir, assets_output);

    // The app's embed static library (aarch64-linux-android — built by
    // the CLI before packaging, or passed via --binary).
    try dir.createDirPath(io, "Libraries");
    if (options.binary_path) |binary_path| try copyFileToDir(allocator, io, dir, binary_path, "Libraries/libnative-sdk.a");

    const readme = try androidProjectReadme(allocator, options.metadata);
    defer allocator.free(readme);
    try writeFile(dir, io, "README.md", readme);
    try writeReport(allocator, dir, io, "package-manifest.zon", options, "libnative-sdk.a", bundle_stats.asset_count);

    var artifact_name: []const u8 = std.fs.path.basename(options.output_path);
    if (try assembleAndroidApk(allocator, io, options)) |apk_name| {
        artifact_name = apk_name;
    }
    return .{ .path = options.output_path, .artifact_name = artifact_name, .target = .android, .asset_count = bundle_stats.asset_count, .web_engine = options.web_engine, .web_layer = webLayerFor(options) };
}

/// Assemble the debug APK inside the generated project when the caller
/// supplied an environment to probe and the Android toolchain + a JDK
/// are installed. Returns the APK file name, or null when assembly was
/// skipped (with the reason printed — never silently).
fn assembleAndroidApk(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !?[]const u8 {
    const env_map = options.env_map orelse {
        std.debug.print("native (android): project emitted without the debug APK (no environment to locate the Android toolchain in this context)\n", .{});
        return null;
    };
    const binary_path = options.binary_path orelse {
        std.debug.print("native (android): project emitted without the debug APK (no embed library was built or passed via --binary)\n", .{});
        return null;
    };
    const tc = (try android_tool.findToolchain(allocator, io, env_map)) orelse return null;
    defer tc.deinit(allocator);
    const java = (try android_tool.resolveJavaAlloc(allocator, io, env_map)) orelse {
        std.debug.print("native (android): project emitted without the debug APK (no JDK found - set JAVA_HOME)\n", .{});
        return null;
    };
    defer allocator.free(java);

    const host_dir = try std.fs.path.join(allocator, &.{ options.output_path, "Host" });
    defer allocator.free(host_dir);
    const work_dir = try std.fs.path.join(allocator, &.{ options.output_path, "build" });
    defer allocator.free(work_dir);
    const so_path = try std.fs.path.join(allocator, &.{ options.output_path, "build-libnative_sdk_host.so" });
    defer allocator.free(so_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ options.output_path, "AndroidManifest.xml" });
    defer allocator.free(manifest_path);
    const res_dir = try std.fs.path.join(allocator, &.{ options.output_path, "res" });
    defer allocator.free(res_dir);
    const assets_dir = try std.fs.path.join(allocator, &.{ options.output_path, "assets", "native-sdk" });
    defer allocator.free(assets_dir);
    const apk_name = try std.fmt.allocPrint(allocator, "{s}-debug.apk", .{options.metadata.name});
    errdefer allocator.free(apk_name);
    const out_apk = try std.fs.path.join(allocator, &.{ options.output_path, apk_name });
    defer allocator.free(out_apk);
    const keystore_path = try android_tool.debugKeystorePathAlloc(allocator, env_map);
    defer allocator.free(keystore_path);

    std.debug.print("native (android): compiling the toolkit host library ({s})\n", .{android_tool.clang_target});
    try android_tool.compileHostLibrary(allocator, io, &tc, host_dir, binary_path, so_path);
    std.debug.print("native (android): assembling {s}\n", .{out_apk});
    try android_tool.assembleApk(allocator, io, .{
        .toolchain = &tc,
        .java = java,
        .work_dir = work_dir,
        .manifest_path = manifest_path,
        .host_dir = host_dir,
        .so_path = so_path,
        .res_dir = res_dir,
        .assets_dir = assets_dir,
        .keystore_path = keystore_path,
        .out_apk = out_apk,
    });
    // The intermediates served their purpose; the .so is preserved in
    // the APK itself.
    std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};
    std.Io.Dir.cwd().deleteFile(io, so_path) catch {};
    return apk_name;
}

fn androidProjectReadme(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\# {s} — Android host project
        \\
        \\Generated by `native package --target android`. Everything here is toolkit-owned output derived from app.zon — regenerate instead of editing.
        \\
        \\- `{s}-debug.apk` — the debug-signed APK, assembled directly with the Android SDK build tools (aapt2, javac, d8, zipalign, apksigner) and the NDK compiler when they are installed; rerun `native package --target android` after installing them if it is missing.
        \\- `Host/` — the toolkit Android host: the activity (canvas presentation, touch/keyboard/IME, safe areas, Paint text measurement) and the JNI bridge over the embed C ABI.
        \\- `AndroidManifest.xml`, `res/` — the app.zon-derived manifest and the launcher icons rendered from the single-source icon pipeline.
        \\- `assets/native-sdk/` — the bundled app assets, mirrored into the app's files directory at first launch.
        \\- `Libraries/libnative-sdk.a` — the app compiled as the embed static library (aarch64-linux-android). The device loop is `native dev --target android`, which rebuilds the library in Debug.
        \\
        \\The APK is debug-signed with the per-user toolkit keystore (~/.native/android/debug.keystore) for installs via `adb install`. Store distribution (Play upload keys, app bundles) stays a manual step, like macOS notarization.
        \\
    , .{ metadata.displayName(), metadata.name });
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

/// Where the macOS bundle carries the app's assets. Frontend apps keep
/// the established Resources/<dist> layout their webview asset root
/// resolves against. Everything else mirrors the asset directory at its
/// app-relative path — Resources/assets by default — so a relative asset
/// path the app uses at runtime ("assets/music/track.mp3") names the
/// same file inside the bundle that it names in a dev run: the packaged
/// macOS host resolves relative asset paths against Resources. An
/// absolute or parent-escaping --assets directory has no app-relative
/// meaning a packaged process could resolve, so it keeps the flat
/// Resources layout.
fn macosAssetOutputPath(allocator: std.mem.Allocator, options: PackageOptions) ![]const u8 {
    if (options.frontend != null) return assetOutputPath(allocator, options.output_path, "Contents/Resources", options);
    if (appRelativeAssetSubpath(options.assets_dir)) |subpath| {
        return std.fs.path.join(allocator, &.{ options.output_path, "Contents/Resources", subpath });
    }
    return std.fs.path.join(allocator, &.{ options.output_path, "Contents/Resources" });
}

/// The asset directory as an app-relative bundle subpath, or null when
/// it cannot honestly be one (empty, ".", absolute, or escaping the app
/// root through a ".." segment).
fn appRelativeAssetSubpath(assets_dir: []const u8) ?[]const u8 {
    if (assets_dir.len == 0 or std.fs.path.isAbsolute(assets_dir)) return null;
    var segments = std.mem.tokenizeAny(u8, assets_dir, "/\\");
    var has_component = false;
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return null;
        if (!std.mem.eql(u8, segment, ".")) has_component = true;
    }
    if (!has_component) return null;
    return assets_dir;
}

fn macosInfoPlist(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata, executable_name: []const u8) ![]const u8 {
    const icon_name = macosIconFile(metadata);
    const bundle_id = try xmlEscapeAlloc(allocator, metadata.id);
    defer allocator.free(bundle_id);
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
    // The About panel's bottom line in packaged bundles: the manifest
    // description rides NSHumanReadableCopyright, the plist key the
    // standard About panel renders as its footer text — the same line
    // dev runs pass to the panel directly.
    const about_line = try macosAboutLine(allocator, metadata);
    defer allocator.free(about_line);
    // CFBundleName is the SHORT user-visible name — the application
    // menu's title next to the Apple menu reads it — while
    // CFBundleDisplayName serves the Finder and longer surfaces. Both
    // carry the manifest display name so every user-facing surface
    // (menu bar, Dock, Gatekeeper prompts) agrees; the manifest `.name`
    // stays the executable's name, exactly like dev runs, whose host
    // titles the application menu with the display name too.
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
        \\{s}{s}{s}
        \\</dict>
        \\</plist>
        \\
    , .{ bundle_id, display_name, display_name, executable, icon, version, version, about_line, document_types, url_types });
}

/// The optional NSHumanReadableCopyright entry (with trailing newline)
/// for the manifest description, or "" when the manifest has none.
fn macosAboutLine(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]const u8 {
    const description = metadata.description orelse return try allocator.dupe(u8, "");
    const escaped = try xmlEscapeAlloc(allocator, description);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "  <key>NSHumanReadableCopyright</key>\n  <string>{s}</string>\n", .{escaped});
}

fn artifactSuffix(target: PackageTarget) []const u8 {
    return switch (target) {
        .macos => ".app",
        .windows, .linux, .ios, .android => "",
    };
}

fn artifactReadme(target: PackageTarget) []const u8 {
    return switch (target) {
        .windows => "Windows native-sdk artifact directory. Installer generation is future work.\n",
        .linux => "Linux native-sdk artifact directory. AppImage, Flatpak, and tarball generation are future work.\n",
        else => "native-sdk artifact directory.\n",
    };
}

// ---------------------------------------------------------------------------
// App icons: one square source image (assets/icon.png or assets/icon.svg
// in app.zon `.icons`) generates every platform's artifacts through the
// built-in pipeline (`app_icon`). A prebuilt container in `.icons` always
// wins untouched for its platform: `.icns` on macOS, `.ico` on Windows.
// Precedence on macOS: explicit .icns > generated-from-image > the SDK
// default icon.
// ---------------------------------------------------------------------------

/// How `.icons` resolves for packaging: at most one prebuilt container
/// per platform plus at most one generatable source (first of each wins).
const IconPlan = struct {
    prebuilt_icns: ?[]const u8 = null,
    prebuilt_ico: ?[]const u8 = null,
    source_path: ?[]const u8 = null,
    source_kind: app_icon_tool.SourceKind = .png,
};

fn resolveIconPlan(metadata: manifest_tool.Metadata) IconPlan {
    var plan: IconPlan = .{};
    for (metadata.icons) |path| {
        if (app_icon_tool.pathHasExtension(path, ".icns")) {
            if (plan.prebuilt_icns == null) plan.prebuilt_icns = path;
        } else if (app_icon_tool.pathHasExtension(path, ".ico")) {
            if (plan.prebuilt_ico == null) plan.prebuilt_ico = path;
        } else if (app_icon_tool.sourceKindForPath(path)) |kind| {
            if (plan.source_path == null) {
                plan.source_path = path;
                plan.source_kind = kind;
            }
        }
    }
    return plan;
}

/// Read and validate the icon source, printing the same teaching
/// diagnostics `native validate` produces. A missing file warns and
/// returns null (packaging falls back per platform); a file that exists
/// but is not a square PNG/supported SVG is an error.
fn loadIconSource(allocator: std.mem.Allocator, io: std.Io, path: []const u8, kind: app_icon_tool.SourceKind) !?app_icon_tool.Source {
    const bytes = readPath(allocator, io, path) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("warning: app icon source {s} was not found; the artifact falls back to the default icon where one exists\n", .{path});
            return null;
        },
        else => return err,
    };
    defer allocator.free(bytes);
    switch (try app_icon_tool.loadSource(allocator, bytes, kind)) {
        .ok => |loaded| {
            if (kind == .png and loaded.width < app_icon_tool.min_recommended_source_size) {
                var buffer: [512]u8 = undefined;
                std.debug.print("{s}\n", .{app_icon_tool.formatSmallSourceMessage(&buffer, path, loaded.width, loaded.height)});
            }
            return loaded;
        },
        .issue => |issue| {
            var buffer: [512]u8 = undefined;
            const message = switch (issue) {
                .not_square => |dims| app_icon_tool.formatNotSquareMessage(&buffer, path, dims.width, dims.height),
                .unsupported => app_icon_tool.formatUnsupportedMessage(&buffer, path),
            };
            std.debug.print("error: {s}\n", .{message});
            return error.InvalidIconSource;
        },
    }
}

fn macosIconFile(metadata: manifest_tool.Metadata) []const u8 {
    // Only a prebuilt .icns keeps its own name; generated and default
    // icons always ship as AppIcon.icns.
    const plan = resolveIconPlan(metadata);
    if (plan.prebuilt_icns) |path| return std.fs.path.basename(path);
    return "AppIcon.icns";
}

fn copyMacosIcon(allocator: std.mem.Allocator, io: std.Io, package_dir: std.Io.Dir, options: PackageOptions) !void {
    const plan = resolveIconPlan(options.metadata);
    if (plan.prebuilt_icns) |path| {
        // Art-directed prebuilt .icns wins untouched.
        try copyMacosResourceIcon(allocator, io, package_dir, path, "configured app icon");
        return;
    }
    if (plan.source_path) |path| {
        if (try loadIconSource(allocator, io, path, plan.source_kind)) |loaded| {
            var source = loaded;
            defer source.deinit(allocator);
            const icns = app_icon_tool.buildIcns(allocator, &source) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    var buffer: [512]u8 = undefined;
                    std.debug.print("error: {s}\n", .{app_icon_tool.formatUnsupportedMessage(&buffer, path)});
                    return error.InvalidIconSource;
                },
            };
            defer allocator.free(icns);
            try writeFile(package_dir, io, "Contents/Resources/AppIcon.icns", icns);
            return;
        }
    }
    try writeFile(package_dir, io, "Contents/Resources/AppIcon.icns", default_icon_icns);
}

/// Linux: the hicolor-theme size set the desktop entry's `Icon=app-icon`
/// name resolves against, generated from the one source image.
fn writeLinuxIcons(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, metadata: manifest_tool.Metadata) !void {
    const plan = resolveIconPlan(metadata);
    const path = plan.source_path orelse {
        if (metadata.icons.len > 0) {
            std.debug.print("note: Linux icons generate from a square .png or .svg in app.zon .icons; a prebuilt .icns/.ico only serves macOS/Windows, so this artifact ships without one\n", .{});
        }
        return;
    };
    var source = (try loadIconSource(allocator, io, path, plan.source_kind)) orelse return;
    defer source.deinit(allocator);
    for (app_icon_tool.linux_sizes) |size| {
        const encoded = app_icon_tool.buildSquarePng(allocator, &source, size) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidIconSource,
        };
        defer allocator.free(encoded);
        const icon_dir = try std.fmt.allocPrint(allocator, "share/icons/hicolor/{d}x{d}/apps", .{ size, size });
        defer allocator.free(icon_dir);
        try dir.createDirPath(io, icon_dir);
        const icon_path = try std.fmt.allocPrint(allocator, "{s}/app-icon.png", .{icon_dir});
        defer allocator.free(icon_path);
        try writeFile(dir, io, icon_path, encoded);
    }
}

/// Windows: a multi-size `.ico` at the artifact root (square, unmasked).
/// A prebuilt `.ico` in `.icons` ships untouched.
fn writeWindowsIcon(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, metadata: manifest_tool.Metadata) !void {
    const plan = resolveIconPlan(metadata);
    if (plan.prebuilt_ico) |path| {
        copyFileToDir(allocator, io, dir, path, "app-icon.ico") catch {
            std.debug.print("warning: configured .ico {s} was not found; the Windows artifact ships without an icon\n", .{path});
        };
        return;
    }
    const path = plan.source_path orelse return;
    var source = (try loadIconSource(allocator, io, path, plan.source_kind)) orelse return;
    defer source.deinit(allocator);
    const ico = app_icon_tool.buildIco(allocator, &source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidIconSource,
    };
    defer allocator.free(ico);
    try writeFile(dir, io, "app-icon.ico", ico);
}

/// iOS: an asset-catalog icon set with the single 1024 universal image
/// modern toolchains take, dropped next to the host skeleton sources.
fn writeIosIcon(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, metadata: manifest_tool.Metadata) !void {
    const plan = resolveIconPlan(metadata);
    var source: app_icon_tool.Source = source: {
        if (plan.source_path) |path| {
            if (try loadIconSource(allocator, io, path, plan.source_kind)) |loaded| break :source loaded;
        }
        // No usable PNG/SVG source (an .icns-only manifest, or a missing
        // file): render the default icon — the generated Xcode project
        // references Assets.xcassets unconditionally, so the catalog must
        // always exist.
        switch (try app_icon_tool.loadSource(allocator, default_icon_png, .png)) {
            .ok => |loaded| break :source loaded,
            // The embedded default is a valid square PNG by construction
            // (`zig build generate-icon` regenerates it).
            .issue => unreachable,
        }
    };
    defer source.deinit(allocator);
    const encoded = app_icon_tool.buildSquarePng(allocator, &source, app_icon_tool.ios_icon_size) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidIconSource,
    };
    defer allocator.free(encoded);
    try dir.createDirPath(io, "Assets.xcassets/AppIcon.appiconset");
    try writeFile(dir, io, "Assets.xcassets/AppIcon.appiconset/AppIcon.png", encoded);
    try writeFile(dir, io, "Assets.xcassets/AppIcon.appiconset/Contents.json",
        \\{
        \\  "images" : [
        \\    {
        \\      "filename" : "AppIcon.png",
        \\      "idiom" : "universal",
        \\      "platform" : "ios",
        \\      "size" : "1024x1024"
        \\    }
        \\  ],
        \\  "info" : {
        \\    "author" : "native",
        \\    "version" : 1
        \\  }
        \\}
        \\
    );
}

/// Android: launcher mipmaps at the standard densities, falling back to
/// the SDK default icon so the generated manifest's @mipmap reference
/// always resolves — the Android mirror of writeIosIcon. (Adaptive icons
/// need two art-directed layers a single flat source cannot honestly
/// provide, so only the legacy launcher set is generated.)
fn writeAndroidIcons(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, metadata: manifest_tool.Metadata) !void {
    const plan = resolveIconPlan(metadata);
    var source: app_icon_tool.Source = source: {
        if (plan.source_path) |path| {
            if (try loadIconSource(allocator, io, path, plan.source_kind)) |loaded| break :source loaded;
        }
        switch (try app_icon_tool.loadSource(allocator, default_icon_png, .png)) {
            .ok => |loaded| break :source loaded,
            // The embedded default is a valid square PNG by construction
            // (`zig build generate-icon` regenerates it).
            .issue => unreachable,
        }
    };
    defer source.deinit(allocator);
    for (app_icon_tool.android_densities) |density| {
        const encoded = app_icon_tool.buildSquarePng(allocator, &source, density.size) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidIconSource,
        };
        defer allocator.free(encoded);
        const mipmap_dir = try std.fmt.allocPrint(allocator, "res/mipmap-{s}", .{density.name});
        defer allocator.free(mipmap_dir);
        try dir.createDirPath(io, mipmap_dir);
        const icon_path = try std.fmt.allocPrint(allocator, "{s}/ic_launcher.png", .{mipmap_dir});
        defer allocator.free(icon_path);
        try writeFile(dir, io, icon_path, encoded);
    }
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

/// The Windows system engine discovers the machine's WebView2 runtime
/// through WebView2Loader.dll, which the host loads from the executable's
/// directory — the vendored copy ships inside every packaged app. The
/// architecture comes from the packaged binary's PE header so an arm64
/// build gets the arm64 loader.
fn copyWindowsWebView2Loader(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: PackageOptions, binary_path: []const u8) !void {
    const framework_root = blk: {
        if (options.env_map) |env_map| {
            if (try buildgraph.resolveFrameworkRoot(allocator, io, env_map)) |root| break :blk root;
        } else if (try buildgraph.frameworkRootFromExecutable(allocator, io)) |root| {
            break :blk root;
        }
        return error.MissingFramework;
    };
    defer allocator.free(framework_root);
    const arch_dir: []const u8 = if (try peExecutableIsArm64(io, binary_path)) "arm64" else "x64";
    const loader_path = try std.fs.path.join(allocator, &.{ framework_root, "third_party", "webview2", arch_dir, "WebView2Loader.dll" });
    defer allocator.free(loader_path);
    try copyFileToDir(allocator, io, dir, loader_path, "bin/WebView2Loader.dll");
}

/// Whether a Windows executable carries the embedded web layer: the host
/// loads WebView2Loader.dll through LoadLibraryW, so the honest evidence
/// is the loader's name in the binary — stored as UTF-16 in a web build
/// and compiled out entirely (with the whole layer) in a native-only
/// build. The same probe as the build-time auditor
/// (tools/audit_web_layer.zig); a non-PE file proves nothing about the
/// layer, so it scans as false rather than refusing the package.
fn peReferencesWebView2Loader(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    const bytes = try readPath(allocator, io, path);
    defer allocator.free(bytes);
    if (bytes.len < 0x40 or bytes[0] != 'M' or bytes[1] != 'Z') return false;
    const pe_offset: usize = std.mem.readInt(u32, bytes[0x3c..0x40], .little);
    if (pe_offset + 4 > bytes.len) return false;
    if (!std.mem.eql(u8, bytes[pe_offset..][0..4], "PE\x00\x00")) return false;
    const needle_ascii = "WebView2Loader.dll";
    var needle_wide: [needle_ascii.len * 2]u8 = undefined;
    for (needle_ascii, 0..) |ch, index| {
        needle_wide[index * 2] = ch;
        needle_wide[index * 2 + 1] = 0;
    }
    return std.mem.indexOf(u8, bytes, &needle_wide) != null or
        std.mem.indexOf(u8, bytes, needle_ascii) != null;
}

/// The Windows subsystem a PE executable declares (IMAGE_OPTIONAL_HEADER
/// Subsystem: 2 = GUI, 3 = console), or null when the file is not a PE
/// with an optional header large enough to say. The packaging check
/// reads this because a console-subsystem GUI app flashes a terminal
/// window behind itself on every launch — `native build` produces
/// GUI-subsystem release exes, so a console one here means a stale or
/// hand-built binary.
pub fn peSubsystem(bytes: []const u8) ?u16 {
    if (bytes.len < 0x40 or bytes[0] != 'M' or bytes[1] != 'Z') return null;
    const pe_offset: usize = std.mem.readInt(u32, bytes[0x3c..0x40], .little);
    if (pe_offset + 24 > bytes.len) return null;
    if (!std.mem.eql(u8, bytes[pe_offset..][0..4], "PE\x00\x00")) return null;
    const optional_size = std.mem.readInt(u16, bytes[pe_offset + 20 ..][0..2], .little);
    // Subsystem sits 68 bytes into the optional header (same offset in
    // PE32 and PE32+).
    if (optional_size < 70) return null;
    const subsystem_offset = pe_offset + 24 + 68;
    if (subsystem_offset + 2 > bytes.len) return null;
    return std.mem.readInt(u16, bytes[subsystem_offset..][0..2], .little);
}

const pe_subsystem_gui: u16 = 2;
const pe_subsystem_console: u16 = 3;

fn peIsConsoleSubsystem(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    const bytes = readPath(allocator, io, path) catch return false;
    defer allocator.free(bytes);
    return (peSubsystem(bytes) orelse return false) == pe_subsystem_console;
}

/// Whether a Linux executable carries the embedded web layer: the GTK
/// host links webkitgtk-6.0 directly, so the honest evidence is a
/// libwebkitgtk/libjavascriptcoregtk DT_NEEDED entry or a webkit_*/jsc_*
/// dynamic-symbol name — all removed by the WebKitGTK compile seam in a
/// native-only build. The same probe as the build-time auditor
/// (tools/audit_web_layer.zig), hand-rolled over the section headers;
/// a non-ELF file (or one this minimal parse cannot walk) proves
/// nothing about the layer, so it scans as false rather than refusing
/// the package.
fn elfReferencesWebKitGtk(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    const bytes = try readPath(allocator, io, path);
    defer allocator.free(bytes);
    return elfBytesReferenceWebKitGtk(bytes);
}

fn elfBytesReferenceWebKitGtk(bytes: []const u8) bool {
    // ELF64 little endian only — every Linux target this toolkit builds.
    if (bytes.len < 0x40 or !std.mem.eql(u8, bytes[0..4], "\x7fELF")) return false;
    if (bytes[4] != 2 or bytes[5] != 1) return false;
    const sh_offset: u64 = std.mem.readInt(u64, bytes[0x28..0x30], .little);
    const sh_entsize: u16 = std.mem.readInt(u16, bytes[0x3a..0x3c], .little);
    const sh_count: u16 = std.mem.readInt(u16, bytes[0x3c..0x3e], .little);
    if (sh_offset == 0 or sh_count == 0 or sh_entsize < 0x40) return false;

    var index: u16 = 0;
    while (index < sh_count) : (index += 1) {
        const header = elfSectionSlice(bytes, sh_offset + @as(u64, index) * sh_entsize, 0x40) orelse return false;
        const sh_type = std.mem.readInt(u32, header[0x04..0x08], .little);
        const link = std.mem.readInt(u32, header[0x28..0x2c], .little);
        const offset = std.mem.readInt(u64, header[0x18..0x20], .little);
        const size = std.mem.readInt(u64, header[0x20..0x28], .little);
        const entsize = std.mem.readInt(u64, header[0x38..0x40], .little);
        // SHT_DYNAMIC = 6, SHT_DYNSYM = 11.
        if (sh_type != 6 and sh_type != 11) continue;
        if (link >= sh_count) continue;
        const link_header = elfSectionSlice(bytes, sh_offset + @as(u64, link) * sh_entsize, 0x40) orelse return false;
        const strtab = elfSectionSlice(bytes, std.mem.readInt(u64, link_header[0x18..0x20], .little), std.mem.readInt(u64, link_header[0x20..0x28], .little)) orelse return false;
        const table = elfSectionSlice(bytes, offset, size) orelse return false;
        if (sh_type == 6) {
            var cursor: usize = 0;
            while (cursor + 16 <= table.len) : (cursor += 16) {
                const tag: i64 = @bitCast(std.mem.readInt(u64, table[cursor..][0..8], .little));
                if (tag != 1) continue; // DT_NEEDED
                const name = elfStringAt(strtab, std.mem.readInt(u64, table[cursor + 8 ..][0..8], .little)) orelse continue;
                if (std.mem.indexOf(u8, name, "webkitgtk") != null or std.mem.indexOf(u8, name, "javascriptcoregtk") != null) return true;
            }
        } else {
            const stride: usize = if (entsize >= 24) @intCast(entsize) else 24;
            var cursor: usize = 0;
            while (cursor + 24 <= table.len) : (cursor += stride) {
                const name_offset: u32 = std.mem.readInt(u32, table[cursor..][0..4], .little);
                if (name_offset == 0) continue;
                const name = elfStringAt(strtab, name_offset) orelse continue;
                if (std.mem.startsWith(u8, name, "webkit_") or std.mem.startsWith(u8, name, "jsc_")) return true;
            }
        }
    }
    return false;
}

fn elfSectionSlice(bytes: []const u8, offset: u64, size: u64) ?[]const u8 {
    if (offset > bytes.len) return null;
    const start: usize = @intCast(offset);
    if (size > bytes.len - start) return null;
    return bytes[start .. start + @as(usize, @intCast(size))];
}

fn elfStringAt(strtab: []const u8, offset: u64) ?[]const u8 {
    if (offset >= strtab.len) return null;
    const start: usize = @intCast(offset);
    const end = std.mem.indexOfScalarPos(u8, strtab, start, 0) orelse return null;
    return strtab[start..end];
}

/// Whether a PE executable targets arm64, read from the COFF machine
/// field. Anything unrecognized falls back to x64, the default Windows
/// build target.
fn peExecutableIsArm64(io: std.Io, path: []const u8) !bool {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var header: [4096]u8 = undefined;
    const len = try reader.interface.readSliceShort(&header);
    if (len < 0x40 or header[0] != 'M' or header[1] != 'Z') return false;
    const pe_offset: usize = std.mem.readInt(u32, header[0x3c..0x40], .little);
    if (pe_offset + 6 > len) return false;
    if (!std.mem.eql(u8, header[pe_offset..][0..4], "PE\x00\x00")) return false;
    const machine = std.mem.readInt(u16, header[pe_offset + 4 ..][0..2], .little);
    return machine == 0xaa64;
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
    // The web-layer verdict the artifact was staged under, in the same
    // "engine (source)" shape the package diagnostic prints — e.g.
    // "none (inferred: nothing in app.zon declares web use)" or
    // "webview2 (declared: capabilities)".
    const layer = webLayerFor(options);
    const web_layer_value = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ webLayerEngineName(layer, options.target, options.web_engine), layer.sourceText() });
    defer allocator.free(web_layer_value);
    const web_layer = try zonStringAlloc(allocator, web_layer_value);
    defer allocator.free(web_layer);
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
        \\  .web_layer = {s},
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
        web_layer,
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

/// Sign the finished bundle and record the signing plan inside it. The
/// plan file lives in Contents/Resources, which codesign seals: writing
/// it AFTER a successful signature would invalidate the resource seal
/// (`codesign --verify --strict` reports "file added" and a quarantined
/// install shows Gatekeeper's "damaged" dialog). So the plan is written
/// BEFORE codesign runs — the sealed file states what was requested and
/// the signature on the bundle is the proof it happened — and only a
/// FAILED signing rewrites it, which is safe because a failed codesign
/// leaves the bundle without a seal to break.
/// Returns true when the bundle was signed AND the signature verified —
/// the value the report's "signed, verified" line states. A signing mode
/// that claims to sign (adhoc or identity) either delivers a verified
/// signature or fails the whole package with codesign's own reason:
/// exiting 0 while shipping an unsigned bundle is the release-breaking
/// failure this pipeline exists to prevent.
fn runSigning(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: PackageOptions) !bool {
    const plan_path = "Contents/Resources/signing-plan.txt";
    switch (options.signing.mode) {
        .none => {
            try writeFile(dir, io, plan_path, "signing=none\nunsigned local package\n");
            return false;
        },
        .adhoc => {
            try writeFile(dir, io, plan_path, "signing=adhoc\nad-hoc signed\n");
            const result = try codesign.signAdHoc(allocator, io, options.output_path);
            defer allocator.free(result.message);
            if (!result.ok) {
                try writeFile(dir, io, plan_path, "signing=adhoc\ncodesign --sign - failed; bundle is unsigned\n");
                std.debug.print("error: ad-hoc code signing failed for {s}, so this package would ship unsigned - codesign said:\n{s}\n  fix what codesign reports above, or package with `--signing none` if an unsigned bundle is what you want\n", .{ options.output_path, trimmedToolOutput(result.message) });
                return error.SigningFailed;
            }
        },
        .identity => {
            const identity = options.signing.identity orelse {
                try writeFile(dir, io, plan_path, "signing=identity\nno identity provided; bundle is unsigned\n");
                std.debug.print("error: --signing identity needs the identity to sign with, so this package would ship unsigned - pass --identity \"Developer ID Application: Your Name (TEAMID)\"\n  `security find-identity -v -p codesigning` lists the identities this machine can sign with\n", .{});
                return error.SigningFailed;
            };
            const plan_text = try std.fmt.allocPrint(allocator, "signing=identity\nsigned with {s}\n", .{identity});
            defer allocator.free(plan_text);
            try writeFile(dir, io, plan_path, plan_text);
            const result = try codesign.signIdentity(allocator, io, options.output_path, identity, options.signing.entitlements);
            defer allocator.free(result.message);
            if (!result.ok) {
                try writeFile(dir, io, plan_path, "signing=identity\ncodesign failed; bundle is unsigned\n");
                std.debug.print("error: code signing with \"{s}\" failed for {s}, so this package would ship unsigned - codesign said:\n{s}\n  `security find-identity -v -p codesigning` lists the identities this machine can sign with\n", .{ identity, options.output_path, trimmedToolOutput(result.message) });
                return error.SigningFailed;
            }
        },
    }
    // The signature just applied must actually hold — the same strict
    // deep check an Apple silicon launch effectively runs. A bundle that
    // signs but does not verify (a stale seal, unsigned nested code) is
    // a packaging failure, not a report footnote.
    const verified = try codesign.verify(allocator, io, options.output_path);
    defer allocator.free(verified.message);
    if (!verified.ok) {
        std.debug.print("error: {s} was signed but failed `codesign --verify --deep --strict`, so it would be rejected at launch - codesign said:\n{s}\n  fix what codesign reports above and rerun `native package`\n", .{ options.output_path, trimmedToolOutput(verified.message) });
        return error.SignatureVerificationFailed;
    }
    return true;
}

/// codesign's output, trimmed of trailing newlines so the teaching
/// message's fix line lands directly under it (the output itself stays
/// verbatim).
fn trimmedToolOutput(output: []const u8) []const u8 {
    return std.mem.trimEnd(u8, output, "\r\n");
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

test "mobile package templates ship the toolkit hosts" {
    // The iOS host tier ships the toolkit-owned UIKit host over the
    // embed ABI (canvas presentation, input, IME, safe areas, CoreText
    // measurement, and the panic-path dyld shim the iOS SDK hides).
    const ios_host = ios_tool.host_source;
    try std.testing.expect(std.mem.indexOf(u8, ios_host, "native_sdk_app_viewport") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_host, "native_sdk_app_render_pixels") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_host, "native_sdk_app_scroll") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_host, "native_sdk_app_text_input_state") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_host, "native_sdk_app_set_text_measure") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_host, "native_sdk_app_set_asset_root") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_host, "native_sdk_app_widget_semantics_by_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_host, "view.safeAreaInsets") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios_host, "_dyld_get_image_header_containing_address") != null);

    // The Android host tier ships the same architecture over JNI: the
    // activity presents pixels, forwards touch/keyboard/IME, reports
    // safe-area and keyboard insets, and registers Paint measurement.
    const android_activity = android_tool.host_activity_source;
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "System.loadLibrary(\"native_sdk_host\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "nativeTextInputState") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "setComposingText") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "finishComposingText") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "InputMethodManager") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "WindowInsets.Type.ime()") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "WindowInsets.Type.displayCutout()") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "nativeScrollableWidgetAt") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "measureText") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_activity, "native-sdk-automation") != null);
    const android_bridge = android_tool.host_bridge_source;
    try std.testing.expect(std.mem.indexOf(u8, android_bridge, "native_sdk_app_viewport") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_bridge, "native_sdk_app_render_pixels") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_bridge, "native_sdk_app_ime") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_bridge, "native_sdk_app_text_input_state") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_bridge, "native_sdk_app_set_text_measure") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_bridge, "native_sdk_app_set_asset_root") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_bridge, "ANativeWindow_fromSurface") != null);
    try std.testing.expect(std.mem.indexOf(u8, android_bridge, "WINDOW_FORMAT_RGBA_8888") != null);
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
        .id = "dev.native-sdk.mobile-app",
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

    const plist = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/ios/Host/Info.plist");
    defer std.testing.allocator.free(plist);
    try std.testing.expect(std.mem.indexOf(u8, plist, "dev.native-sdk.mobile-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "Mobile Demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "2.3.4") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "UILaunchScreen") != null);

    // The generated Xcode project ties the host, library, and resources
    // together with the app.zon identity — archive-ready with zero edits.
    const pbxproj = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/ios/mobile-demo.xcodeproj/project.pbxproj");
    defer std.testing.allocator.free(pbxproj);
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "PRODUCT_BUNDLE_IDENTIFIER = \"dev.native-sdk.mobile-app\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "PRODUCT_NAME = \"mobile-demo\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "MARKETING_VERSION = \"2.3.4\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "INFOPLIST_FILE = \"Host/Info.plist\";") != null);
    const scheme = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/ios/mobile-demo.xcodeproj/xcshareddata/xcschemes/mobile-demo.xcscheme");
    defer std.testing.allocator.free(scheme);
    try std.testing.expect(std.mem.indexOf(u8, scheme, "BuildableName = \"mobile-demo.app\"") != null);
    const packaged_host = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/ios/Host/uikit_host.m");
    defer std.testing.allocator.free(packaged_host);
    try std.testing.expectEqualStrings(ios_tool.host_source, packaged_host);
    var ios_libraries = try cwd.openDir(std.testing.io, ".zig-cache/test-package-mobile-identity/ios/Libraries", .{});
    ios_libraries.close(std.testing.io);

    // The generated Android host project ties the manifest, host
    // sources, and resources together with the app.zon identity — the
    // debug APK assembles with zero edits when the toolchain is present
    // (skipped here: unit tests pass no environment to probe).
    const manifest = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/android/AndroidManifest.xml");
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "package=\"dev.native_sdk.mobile_app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "android:versionName=\"2.3.4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "android:label=\"Mobile Demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "android:name=\"dev.native_sdk.host.NativeSdkActivity\"") != null);
    const packaged_activity = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/android/Host/NativeSdkActivity.java");
    defer std.testing.allocator.free(packaged_activity);
    try std.testing.expectEqualStrings(android_tool.host_activity_source, packaged_activity);
    const packaged_bridge = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/android/Host/android_host.c");
    defer std.testing.allocator.free(packaged_bridge);
    try std.testing.expectEqualStrings(android_tool.host_bridge_source, packaged_bridge);
    const launcher_icon = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/android/res/mipmap-xxxhdpi/ic_launcher.png");
    defer std.testing.allocator.free(launcher_icon);
    try std.testing.expect(launcher_icon.len > 8);
    var android_libraries = try cwd.openDir(std.testing.io, ".zig-cache/test-package-mobile-identity/android/Libraries", .{});
    android_libraries.close(std.testing.io);

    const ios_asset = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/ios/Assets/dist/main.html");
    defer std.testing.allocator.free(ios_asset);
    try std.testing.expectEqualStrings("<h1>Mobile</h1>", ios_asset);

    const android_asset = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-mobile-identity/android/assets/native-sdk/dist/main.html");
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
        .id = "dev.native-sdk.mobile-chromium",
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
    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .display_name = "Demo App", .description = "A demo of the packaging pipeline.", .version = "1.2.3", .icons = &.{"assets/icon.icns"} };
    const plist = try macosInfoPlist(std.testing.allocator, metadata, "demo");
    defer std.testing.allocator.free(plist);
    try std.testing.expect(std.mem.indexOf(u8, plist, "CFBundleIdentifier") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "CFBundleDisplayName") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "dev.example.app") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "Demo App") != null);
    // CFBundleName is what the application menu shows: it must carry the
    // display name, never the lowercase manifest/executable name.
    try std.testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleName</key>\n  <string>Demo App</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<string>demo</string>\n  <key>CFBundleDisplayName</key>") == null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleExecutable</key>\n  <string>demo</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "icon.icns") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "LSMinimumSystemVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "11.0") != null);
    // The manifest description reaches the About panel's footer key.
    try std.testing.expect(std.mem.indexOf(u8, plist, "NSHumanReadableCopyright") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "A demo of the packaging pipeline.") != null);

    // Without a description the key is absent, not emitted empty.
    const bare: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .version = "1.2.3" };
    const bare_plist = try macosInfoPlist(std.testing.allocator, bare, "demo");
    defer std.testing.allocator.free(bare_plist);
    try std.testing.expect(std.mem.indexOf(u8, bare_plist, "NSHumanReadableCopyright") == null);
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

test "macOS package mirrors app assets at their app-relative path" {
    // The packaged host resolves relative asset paths against
    // Contents/Resources, so the bundle must carry the asset tree at the
    // same relative paths a dev run reads ("assets/music/track.mp3" →
    // Resources/assets/music/track.mp3) — never flattened into the
    // Resources root where no runtime path ever finds it.
    var cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(std.testing.io, ".zig-cache/test-package-asset-layout");
    defer cwd.deleteTree(std.testing.io, ".zig-cache/test-package-asset-layout") catch {};
    try cwd.createDirPath(std.testing.io, ".zig-cache/test-package-asset-layout/assets/music");
    try cwd.writeFile(std.testing.io, .{ .sub_path = ".zig-cache/test-package-asset-layout/assets/music/track.mp3", .data = "mp3-bytes" });

    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .version = "1.2.3" };
    const stats = try createMacosApp(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .output_path = ".zig-cache/test-package-asset-layout/Demo.app",
        .assets_dir = ".zig-cache/test-package-asset-layout/assets",
    });
    try std.testing.expectEqual(@as(usize, 1), stats.asset_count);

    const bundled = try readPath(std.testing.allocator, std.testing.io, ".zig-cache/test-package-asset-layout/Demo.app/Contents/Resources/.zig-cache/test-package-asset-layout/assets/music/track.mp3");
    defer std.testing.allocator.free(bundled);
    try std.testing.expectEqualStrings("mp3-bytes", bundled);
}

test "app-relative asset subpaths accept plain trees and reject escapes" {
    try std.testing.expectEqualStrings("assets", appRelativeAssetSubpath("assets").?);
    try std.testing.expectEqualStrings("data/sounds", appRelativeAssetSubpath("data/sounds").?);
    try std.testing.expect(appRelativeAssetSubpath("") == null);
    try std.testing.expect(appRelativeAssetSubpath(".") == null);
    try std.testing.expect(appRelativeAssetSubpath("./.") == null);
    try std.testing.expect(appRelativeAssetSubpath("../shared") == null);
    try std.testing.expect(appRelativeAssetSubpath("assets/../..") == null);
    try std.testing.expect(appRelativeAssetSubpath("/tmp/assets") == null);
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

test "adhoc packaging into a spaced output path signs and verifies" {
    // The reported release-breaker: `--output "<path with spaces>.app"`
    // packaged, exited 0, and shipped an UNSIGNED bundle because the
    // codesign command was a shell string the spaces split apart. The
    // pipeline now execs argv arrays, so the spaced path must sign — and
    // the strict deep verify (real codesign, darwin hosts only) is the
    // proof.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package signed spaced";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");

    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.spaced-sign", .name = "spaced-demo", .version = "1.0.0" };
    const app_path = root ++ "/My Spaced Demo.app";
    const stats = try createMacosApp(gpa, std.testing.io, .{
        .metadata = metadata,
        .output_path = app_path,
        // A real Mach-O executable, so codesign has honest code to sign.
        .binary_path = "/bin/ls",
        .assets_dir = root ++ "/assets",
        .signing = .{ .mode = .adhoc },
    });
    try std.testing.expectEqual(SigningMode.adhoc, stats.signing_mode);
    try std.testing.expect(stats.signing_verified);

    // Pin the claim with an independent codesign run, not just the flag.
    const verified = try codesign.verify(gpa, std.testing.io, app_path);
    defer gpa.free(verified.message);
    try std.testing.expect(verified.ok);
}

test "a codesign failure fails packaging instead of shipping unsigned" {
    // An identity codesign cannot resolve exits nonzero; packaging must
    // surface that as an error (with codesign's reason printed), never
    // as a created artifact. Real codesign run: darwin hosts only.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-signing-failure";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");

    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.sign-fail", .name = "sign-fail-demo", .version = "1.0.0" };
    try std.testing.expectError(error.SigningFailed, createMacosApp(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .output_path = root ++ "/Sign Fail Demo.app",
        .binary_path = "/bin/ls",
        .assets_dir = root ++ "/assets",
        .signing = .{ .mode = .identity, .identity = "native-sdk-no-such-identity" },
    }));
}

test "identity signing without an identity is a loud failure, not a silent unsigned bundle" {
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-signing-no-identity";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");

    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.no-identity", .name = "no-identity-demo", .version = "1.0.0" };
    try std.testing.expectError(error.SigningFailed, createMacosApp(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .output_path = root ++ "/NoIdentity.app",
        .assets_dir = root ++ "/assets",
        .signing = .{ .mode = .identity },
    }));
}

test "native-only windows package ships no WebView2 loader and reports web layer none" {
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-native-only-windows";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/app-binary", .data = "not a real exe" });

    // A canvas app shape: gpu capabilities, no frontend, no webview.
    const capabilities = [_][]const u8{ "native_views", "gpu_surfaces" };
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.canvas",
        .name = "canvas-demo",
        .version = "1.0.0",
        .capabilities = &capabilities,
    };

    const stats = try createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .windows,
        .output_path = root ++ "/demo-windows",
        .binary_path = root ++ "/app-binary",
        .assets_dir = root ++ "/assets",
    });
    try std.testing.expect(!stats.web_layer.?.enabled);

    // No loader staged next to the binary.
    var dir = try cwd.openDir(std.testing.io, root ++ "/demo-windows", .{});
    defer dir.close(std.testing.io);
    try std.testing.expectError(error.FileNotFound, dir.openFile(std.testing.io, "bin/WebView2Loader.dll", .{}));

    // No frontend dist directory (native-only packages bundle plain assets).
    try std.testing.expectError(error.FileNotFound, dir.openDir(std.testing.io, "resources/dist", .{}));

    // The report carries the verdict.
    const report = try readPath(std.testing.allocator, std.testing.io, root ++ "/demo-windows/package-manifest.zon");
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, ".web_layer = \"none (inferred: nothing in app.zon declares web use)\"") != null);
}

test "webview-declaring package reports the web layer as declared" {
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-web-layer-declared";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");

    const capabilities = [_][]const u8{ "webview", "js_bridge" };
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.web",
        .name = "web-demo",
        .version = "1.0.0",
        .capabilities = &capabilities,
    };

    // No binary: the loader copy is not exercised (it needs a framework
    // root), but the report and stats still carry the declared verdict.
    const stats = try createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .windows,
        .output_path = root ++ "/demo-windows",
        .assets_dir = root ++ "/assets",
    });
    try std.testing.expect(stats.web_layer.?.enabled);
    try std.testing.expectEqual(manifest_tool.WebLayerReason.capability, stats.web_layer.?.reason);

    const report = try readPath(std.testing.allocator, std.testing.io, root ++ "/demo-windows/package-manifest.zon");
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, ".web_layer = \"webview2 (declared: capabilities)\"") != null);
}

test "package refuses a manifest that excludes the web layer while declaring web content" {
    const capabilities = [_][]const u8{"webview"};
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.conflict",
        .name = "conflict-demo",
        .version = "1.0.0",
        .capabilities = &capabilities,
        .webview_layer = "exclude",
    };
    try std.testing.expectError(error.WebViewLayerConflict, createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .windows,
        .output_path = ".zig-cache/test-package-web-layer-conflict",
    }));
}

test "package web layer follows the resolved engine, not the raw manifest" {
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-web-layer-resolved-engine";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/assets/index.html", .data = "<h1>Web</h1>" });

    // A system manifest with no web declarations, packaged with the
    // engine the CLI resolved from `--web-engine chromium`: the layer
    // ships, and the verdict names the engine as the cause.
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.resolved",
        .name = "resolved-demo",
        .version = "1.0.0",
    };
    const stats = try createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .ios,
        .output_path = root ++ "/ios",
        .assets_dir = root ++ "/assets",
        .web_engine = .chromium,
    });
    try std.testing.expect(stats.web_layer.?.enabled);
    try std.testing.expectEqual(manifest_tool.WebLayerReason.chromium_engine, stats.web_layer.?.reason);
}

test "package refuses an exclude against a resolved Chromium engine" {
    // `.webview_layer = "exclude"` with `--web-engine chromium` is the
    // same contradiction as exclude + a manifest web declaration: the
    // package boundary rejects it exactly like build configure does.
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.exclude-chromium",
        .name = "exclude-chromium-demo",
        .version = "1.0.0",
        .webview_layer = "exclude",
    };
    try std.testing.expectError(error.WebViewLayerConflict, createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .macos,
        .output_path = ".zig-cache/test-package-web-layer-exclude-chromium",
        .web_engine = .chromium,
    }));
}

/// A minimal Windows executable for web-layer packaging tests: a valid
/// PE header (so the loader-reference scan and the arch sniff both treat
/// it as a real exe) followed by the UTF-16 loader name a web build
/// carries. The COFF machine field stays zero, which the arch sniff
/// reads as x64.
fn testWebLayerPeBytes() [0x80 + "WebView2Loader.dll".len * 2]u8 {
    var bytes = [_]u8{0} ** (0x80 + "WebView2Loader.dll".len * 2);
    bytes[0] = 'M';
    bytes[1] = 'Z';
    std.mem.writeInt(u32, bytes[0x3c..0x40], 0x40, .little);
    bytes[0x40] = 'P';
    bytes[0x41] = 'E';
    for ("WebView2Loader.dll", 0..) |ch, index| {
        bytes[0x80 + index * 2] = ch;
    }
    return bytes;
}

/// A minimal Windows executable with a real optional header for the
/// subsystem tests: MZ + PE + a COFF header declaring a 240-byte
/// optional header, with the Subsystem field set as asked.
fn testSubsystemPeBytes(subsystem: u16) [0x200]u8 {
    var bytes = [_]u8{0} ** 0x200;
    bytes[0] = 'M';
    bytes[1] = 'Z';
    std.mem.writeInt(u32, bytes[0x3c..0x40], 0x40, .little);
    bytes[0x40] = 'P';
    bytes[0x41] = 'E';
    // COFF SizeOfOptionalHeader (PE32+ is 240 bytes).
    std.mem.writeInt(u16, bytes[0x54..0x56], 240, .little);
    // Optional header starts at 0x58; Subsystem sits 68 bytes in.
    std.mem.writeInt(u16, bytes[0x9c..0x9e], subsystem, .little);
    return bytes;
}

test "peSubsystem reads the optional header and refuses non-PE bytes" {
    const gui = testSubsystemPeBytes(2);
    try std.testing.expectEqual(@as(?u16, 2), peSubsystem(&gui));
    const console = testSubsystemPeBytes(3);
    try std.testing.expectEqual(@as(?u16, 3), peSubsystem(&console));
    // The loader-scan fixture has no optional header: no subsystem claim.
    const headerless = testWebLayerPeBytes();
    try std.testing.expectEqual(@as(?u16, null), peSubsystem(&headerless));
    try std.testing.expectEqual(@as(?u16, null), peSubsystem("not a pe"));
}

test "windows package pins the exe's subsystem: GUI is quiet, console warns in the stats" {
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-subsystem";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.subsystem",
        .name = "subsystem-demo",
        .version = "1.0.0",
    };

    // The exe `native build` installs: GUI subsystem, no console flash —
    // the package carries no console finding.
    const gui_bytes = testSubsystemPeBytes(2);
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/gui.exe", .data = &gui_bytes });
    const gui_stats = try createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .windows,
        .output_path = root ++ "/gui-package",
        .binary_path = root ++ "/gui.exe",
        .assets_dir = root ++ "/assets",
    });
    try std.testing.expect(!gui_stats.windows_console_subsystem);

    // A stale or hand-built console-subsystem exe: packaged (the app
    // still works), but the stats carry the finding the warning teaches.
    const console_bytes = testSubsystemPeBytes(3);
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/console.exe", .data = &console_bytes });
    const console_stats = try createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .windows,
        .output_path = root ++ "/console-package",
        .binary_path = root ++ "/console.exe",
        .assets_dir = root ++ "/assets",
    });
    try std.testing.expect(console_stats.windows_console_subsystem);
}

test "package --web-layer include on a canvas manifest stages the loader and names the flag" {
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-web-layer-include-flag";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    // The exe a `zig build package -Dweb-layer=include` graph produces on
    // a canvas manifest: a real PE that references the loader.
    const exe_bytes = testWebLayerPeBytes();
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/app.exe", .data = &exe_bytes });

    const capabilities = [_][]const u8{ "native_views", "gpu_surfaces" };
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.canvas",
        .name = "canvas-demo",
        .version = "1.0.0",
        .capabilities = &capabilities,
    };

    // The loader copy resolves the framework root from the environment.
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("NATIVE_SDK_PATH", ".");

    const stats = try createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .windows,
        .output_path = root ++ "/demo-windows",
        .binary_path = root ++ "/app.exe",
        .assets_dir = root ++ "/assets",
        .web_layer_setting = .include,
        .env_map = &env_map,
    });
    try std.testing.expect(stats.web_layer.?.enabled);
    try std.testing.expectEqual(manifest_tool.WebLayerReason.declared_include, stats.web_layer.?.reason);

    // The loader is staged next to the binary, exactly like a manifest
    // that declares web use.
    var dir = try cwd.openDir(std.testing.io, root ++ "/demo-windows", .{});
    defer dir.close(std.testing.io);
    var loader = try dir.openFile(std.testing.io, "bin/WebView2Loader.dll", .{});
    loader.close(std.testing.io);

    // The report names the flag as the cause, not app.zon.
    const report = try readPath(std.testing.allocator, std.testing.io, root ++ "/demo-windows/package-manifest.zon");
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, ".web_layer = \"webview2 (declared: --web-layer include)\"") != null);
}

test "package --web-layer exclude on a web manifest is the same refused conflict" {
    const capabilities = [_][]const u8{"webview"};
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.flag-conflict",
        .name = "flag-conflict-demo",
        .version = "1.0.0",
        .capabilities = &capabilities,
    };
    try std.testing.expectError(error.WebViewLayerConflict, createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .windows,
        .output_path = ".zig-cache/test-package-web-layer-flag-conflict",
        .web_layer_setting = .exclude,
    }));
}

test "package forwarded include on a web manifest keeps the manifest's reason" {
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-web-layer-forwarded-include";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");

    // The build graphs forward `--web-layer include` for every web app;
    // the verdict must keep reporting the manifest's own declaration, so
    // graph-driven and hand-run packages read identically.
    const capabilities = [_][]const u8{"webview"};
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.forwarded",
        .name = "forwarded-demo",
        .version = "1.0.0",
        .capabilities = &capabilities,
    };
    const stats = try createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .windows,
        .output_path = root ++ "/demo-windows",
        .assets_dir = root ++ "/assets",
        .web_layer_setting = .include,
    });
    try std.testing.expect(stats.web_layer.?.enabled);
    try std.testing.expectEqual(manifest_tool.WebLayerReason.capability, stats.web_layer.?.reason);
}

test "package refuses to strip the loader from an exe that references it" {
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-web-layer-mismatch";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    const exe_bytes = testWebLayerPeBytes();
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/app.exe", .data = &exe_bytes });

    // A loader-referencing exe (built with the web layer) packaged under
    // a native-only decision would ship broken webviews: refused, with
    // `--web-layer include` as the way out. Non-PE payloads (the other
    // tests' fake binaries) prove nothing and stay packageable.
    const capabilities = [_][]const u8{ "native_views", "gpu_surfaces" };
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.mismatch",
        .name = "mismatch-demo",
        .version = "1.0.0",
        .capabilities = &capabilities,
    };
    try std.testing.expectError(error.WebViewLayerMismatch, createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .windows,
        .output_path = root ++ "/demo-windows",
        .binary_path = root ++ "/app.exe",
        .assets_dir = root ++ "/assets",
    }));
}

/// A minimal but structurally valid ELF64 executable for the WebKitGTK
/// scan: one .dynstr, one .dynamic with a single DT_NEEDED naming
/// `needed_lib`, and one .dynsym whose single real symbol is named
/// `symbol_name` — the two evidence channels the Linux web-layer guard
/// reads. Caller frees.
fn testWebLayerElfBytes(gpa: std.mem.Allocator, needed_lib: []const u8, symbol_name: []const u8) ![]u8 {
    const dynstr_offset: u64 = 0x100;
    const dynamic_offset: u64 = 0x180;
    const dynsym_offset: u64 = 0x1c0;
    const shdr_offset: u64 = 0x200;
    const bytes = try gpa.alloc(u8, 0x2c0);
    @memset(bytes, 0);

    // ELF header: magic, ELFCLASS64, little endian, section table.
    @memcpy(bytes[0..4], "\x7fELF");
    bytes[4] = 2;
    bytes[5] = 1;
    std.mem.writeInt(u64, bytes[0x28..0x30], shdr_offset, .little);
    std.mem.writeInt(u16, bytes[0x3a..0x3c], 0x40, .little);
    std.mem.writeInt(u16, bytes[0x3c..0x3e], 3, .little);

    // .dynstr: "\0<needed_lib>\0<symbol_name>\0".
    const lib_name_offset: u64 = 1;
    const symbol_name_offset: u64 = 1 + needed_lib.len + 1;
    const dynstr_len: u64 = symbol_name_offset + symbol_name.len + 1;
    @memcpy(bytes[@intCast(dynstr_offset + lib_name_offset)..][0..needed_lib.len], needed_lib);
    @memcpy(bytes[@intCast(dynstr_offset + symbol_name_offset)..][0..symbol_name.len], symbol_name);

    // .dynamic: DT_NEEDED -> needed_lib, then DT_NULL.
    std.mem.writeInt(u64, bytes[@intCast(dynamic_offset)..][0..8], 1, .little); // DT_NEEDED
    std.mem.writeInt(u64, bytes[@intCast(dynamic_offset + 8)..][0..8], lib_name_offset, .little);

    // .dynsym: the null symbol, then one named symbol.
    std.mem.writeInt(u32, bytes[@intCast(dynsym_offset + 24)..][0..4], @intCast(symbol_name_offset), .little);

    // Section headers: [0] .dynstr (SHT_STRTAB), [1] .dynamic, [2] .dynsym.
    const shdr = struct {
        fn write(buffer: []u8, base: u64, index: u64, sh_type: u32, link: u32, offset: u64, size: u64, entsize: u64) void {
            const header = buffer[@intCast(base + index * 0x40)..][0..0x40];
            std.mem.writeInt(u32, header[0x04..0x08], sh_type, .little);
            std.mem.writeInt(u64, header[0x18..0x20], offset, .little);
            std.mem.writeInt(u64, header[0x20..0x28], size, .little);
            std.mem.writeInt(u32, header[0x28..0x2c], link, .little);
            std.mem.writeInt(u64, header[0x38..0x40], entsize, .little);
        }
    };
    shdr.write(bytes, shdr_offset, 0, 3, 0, dynstr_offset, dynstr_len, 0);
    shdr.write(bytes, shdr_offset, 1, 6, 0, dynamic_offset, 32, 16);
    shdr.write(bytes, shdr_offset, 2, 11, 0, dynsym_offset, 48, 24);
    return bytes;
}

test "the linux web-layer scan reads DT_NEEDED and dynamic symbols" {
    const gpa = std.testing.allocator;
    // The library link is evidence on its own.
    const linked = try testWebLayerElfBytes(gpa, "libwebkitgtk-6.0.so.4", "gtk_init");
    defer gpa.free(linked);
    try std.testing.expect(elfBytesReferenceWebKitGtk(linked));
    // So is a lone webkit_/jsc_ dynamic symbol (a hand-linked binary
    // that dodged the DT_NEEDED entry still calls into WebKit).
    const symboled = try testWebLayerElfBytes(gpa, "libgtk-4.so.1", "webkit_web_view_new");
    defer gpa.free(symboled);
    try std.testing.expect(elfBytesReferenceWebKitGtk(symboled));
    const jsc = try testWebLayerElfBytes(gpa, "libgtk-4.so.1", "jsc_value_to_string");
    defer gpa.free(jsc);
    try std.testing.expect(elfBytesReferenceWebKitGtk(jsc));
    // A WebKit-free GTK binary scans clean, and a non-ELF payload
    // proves nothing (stays packageable), mirroring the PE probe.
    const clean = try testWebLayerElfBytes(gpa, "libgtk-4.so.1", "gtk_init");
    defer gpa.free(clean);
    try std.testing.expect(!elfBytesReferenceWebKitGtk(clean));
    try std.testing.expect(!elfBytesReferenceWebKitGtk("not an executable"));
}

test "package refuses to strip WebKitGTK from a Linux binary that links it" {
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-web-layer-linux-mismatch";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    const elf_bytes = try testWebLayerElfBytes(std.testing.allocator, "libwebkitgtk-6.0.so.4", "webkit_web_view_new");
    defer std.testing.allocator.free(elf_bytes);
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/app", .data = elf_bytes });

    // A WebKitGTK-linking binary (built with the web layer) packaged
    // under a native-only decision would ship broken webviews AND a
    // libwebkitgtk runtime requirement the package claims not to have:
    // refused, with `--web-layer include` as the way out.
    const capabilities = [_][]const u8{ "native_views", "gpu_surfaces" };
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.linux-mismatch",
        .name = "linux-mismatch-demo",
        .version = "1.0.0",
        .capabilities = &capabilities,
    };
    try std.testing.expectError(error.WebViewLayerMismatch, createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .linux,
        .output_path = root ++ "/demo-linux",
        .binary_path = root ++ "/app",
        .assets_dir = root ++ "/assets",
    }));
}

test "native-only linux package accepts a WebKit-free ELF and reports web layer none" {
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-web-layer-linux-clean";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    const elf_bytes = try testWebLayerElfBytes(std.testing.allocator, "libgtk-4.so.1", "gtk_init");
    defer std.testing.allocator.free(elf_bytes);
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/app", .data = elf_bytes });

    const capabilities = [_][]const u8{ "native_views", "gpu_surfaces" };
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.linux-clean",
        .name = "linux-clean-demo",
        .version = "1.0.0",
        .capabilities = &capabilities,
    };
    const stats = try createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .linux,
        .output_path = root ++ "/demo-linux",
        .binary_path = root ++ "/app",
        .assets_dir = root ++ "/assets",
    });
    try std.testing.expect(!stats.web_layer.?.enabled);

    const report = try readPath(std.testing.allocator, std.testing.io, root ++ "/demo-linux/package-manifest.zon");
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, ".web_layer = \"none (inferred: nothing in app.zon declares web use)\"") != null);
}

// ---------------------------------------------------------------------------
// App icon pipeline tests
// ---------------------------------------------------------------------------

/// Write a solid full-bleed square PNG source for icon tests.
fn writeTestIconSource(gpa: std.mem.Allocator, io: std.Io, path: []const u8, extent: usize) !void {
    const pixels = try gpa.alloc(u8, extent * extent * 4);
    defer gpa.free(pixels);
    var index: usize = 0;
    while (index < extent * extent) : (index += 1) {
        pixels[index * 4 + 0] = 40;
        pixels[index * 4 + 1] = 90;
        pixels[index * 4 + 2] = 220;
        pixels[index * 4 + 3] = 255;
    }
    const encoded = try app_icon_tool.encodePng(gpa, pixels, extent, extent);
    defer gpa.free(encoded);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = encoded });
}

test "macos package generates a full icns family from a png source" {
    const gpa = std.testing.allocator;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-icon-gen";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    try writeTestIconSource(gpa, std.testing.io, root ++ "/assets/icon.png", 128);

    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.app",
        .name = "demo",
        .version = "1.0.0",
        .icons = &.{root ++ "/assets/icon.png"},
    };
    _ = try createMacosApp(gpa, std.testing.io, .{
        .metadata = metadata,
        .output_path = root ++ "/Demo.app",
        .assets_dir = root ++ "/assets",
    });

    const icns = try readPath(gpa, std.testing.io, root ++ "/Demo.app/Contents/Resources/AppIcon.icns");
    defer gpa.free(icns);
    var iterator = app_icon_tool.IcnsIterator.init(icns) orelse return error.TestUnexpectedResult;
    var seen: usize = 0;
    while (iterator.next()) |member| {
        const slot = app_icon_tool.icns_slots[seen];
        try std.testing.expectEqualSlices(u8, &slot.kind, &member.kind);
        switch (slot.payload) {
            .png => {
                const header = app_icon_tool.pngHeader(member.data) orelse return error.TestUnexpectedResult;
                try std.testing.expectEqual(slot.size, header.width);
                try std.testing.expectEqual(slot.size, header.height);
            },
            .argb => {
                const rgba = try app_icon_tool.decodeArgb(gpa, member.data, slot.size, slot.size);
                defer gpa.free(rgba);
                try std.testing.expectEqual(slot.size * slot.size * 4, rgba.len);
            },
        }
        seen += 1;
    }
    try std.testing.expectEqual(app_icon_tool.icns_slots.len, seen);

    // The Info.plist references the generated name, not the source name.
    const plist = try readPath(gpa, std.testing.io, root ++ "/Demo.app/Contents/Info.plist");
    defer gpa.free(plist);
    try std.testing.expect(std.mem.indexOf(u8, plist, "AppIcon.icns") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "icon.png") == null);
}

test "a prebuilt icns wins untouched over a png source" {
    const gpa = std.testing.allocator;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-icon-precedence";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    try writeTestIconSource(gpa, std.testing.io, root ++ "/assets/icon.png", 64);
    const prebuilt = "icns\x00\x00\x00\x0cJUNK";
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/assets/icon.icns", .data = prebuilt });

    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.app",
        .name = "demo",
        .version = "1.0.0",
        // Source listed FIRST: the prebuilt .icns must still win.
        .icons = &.{ root ++ "/assets/icon.png", root ++ "/assets/icon.icns" },
    };
    _ = try createMacosApp(gpa, std.testing.io, .{
        .metadata = metadata,
        .output_path = root ++ "/Demo.app",
        .assets_dir = root ++ "/assets",
    });

    const copied = try readPath(gpa, std.testing.io, root ++ "/Demo.app/Contents/Resources/icon.icns");
    defer gpa.free(copied);
    try std.testing.expectEqualStrings(prebuilt, copied);
}

test "macos package without icons ships the default icon" {
    const gpa = std.testing.allocator;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-icon-default";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");

    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .version = "1.0.0" };
    _ = try createMacosApp(gpa, std.testing.io, .{
        .metadata = metadata,
        .output_path = root ++ "/Demo.app",
        .assets_dir = root ++ "/assets",
    });
    const icns = try readPath(gpa, std.testing.io, root ++ "/Demo.app/Contents/Resources/AppIcon.icns");
    defer gpa.free(icns);
    try std.testing.expect(app_icon_tool.IcnsIterator.init(icns) != null);
}

test "a non-square icon source fails packaging with the teaching error" {
    const gpa = std.testing.allocator;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-icon-nonsquare";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    const pixels = try gpa.alloc(u8, 6 * 4 * 4);
    defer gpa.free(pixels);
    @memset(pixels, 255);
    const encoded = try app_icon_tool.encodePng(gpa, pixels, 6, 4);
    defer gpa.free(encoded);
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/assets/icon.png", .data = encoded });

    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.app",
        .name = "demo",
        .version = "1.0.0",
        .icons = &.{root ++ "/assets/icon.png"},
    };
    try std.testing.expectError(error.InvalidIconSource, createMacosApp(gpa, std.testing.io, .{
        .metadata = metadata,
        .output_path = root ++ "/Demo.app",
        .assets_dir = root ++ "/assets",
    }));
}

test "linux artifact installs the hicolor icon size set" {
    const gpa = std.testing.allocator;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-icon-linux";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    try writeTestIconSource(gpa, std.testing.io, root ++ "/assets/icon.png", 64);

    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.app",
        .name = "demo",
        .version = "1.0.0",
        .icons = &.{root ++ "/assets/icon.png"},
    };
    _ = try createPackage(gpa, std.testing.io, .{
        .metadata = metadata,
        .target = .linux,
        .output_path = root ++ "/demo-linux",
        .assets_dir = root ++ "/assets",
    });

    inline for (app_icon_tool.linux_sizes) |size| {
        const icon_path = try std.fmt.allocPrint(gpa, "{s}/demo-linux/share/icons/hicolor/{d}x{d}/apps/app-icon.png", .{ root, size, size });
        defer gpa.free(icon_path);
        const encoded = try readPath(gpa, std.testing.io, icon_path);
        defer gpa.free(encoded);
        const header = app_icon_tool.pngHeader(encoded) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, size), header.width);
        try std.testing.expectEqual(@as(usize, size), header.height);
    }
}

test "windows artifact gets a generated multi-size ico" {
    const gpa = std.testing.allocator;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-icon-windows";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    try writeTestIconSource(gpa, std.testing.io, root ++ "/assets/icon.png", 64);

    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.app",
        .name = "demo",
        .version = "1.0.0",
        .icons = &.{root ++ "/assets/icon.png"},
    };
    _ = try createPackage(gpa, std.testing.io, .{
        .metadata = metadata,
        .target = .windows,
        .output_path = root ++ "/demo-windows",
        .assets_dir = root ++ "/assets",
    });

    const ico = try readPath(gpa, std.testing.io, root ++ "/demo-windows/app-icon.ico");
    defer gpa.free(ico);
    var iterator = app_icon_tool.IcoIterator.init(ico) orelse return error.TestUnexpectedResult;
    var seen: usize = 0;
    while (iterator.next()) |entry| {
        try std.testing.expectEqual(app_icon_tool.ico_sizes[seen], entry.size);
        const header = app_icon_tool.pngHeader(entry.data) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(app_icon_tool.ico_sizes[seen], header.width);
        seen += 1;
    }
    try std.testing.expectEqual(app_icon_tool.ico_sizes.len, seen);
}

test "ios artifact carries the asset-catalog icon set" {
    const gpa = std.testing.allocator;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-icon-ios";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    try writeTestIconSource(gpa, std.testing.io, root ++ "/assets/icon.png", 64);

    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.app",
        .name = "demo",
        .version = "1.0.0",
        .icons = &.{root ++ "/assets/icon.png"},
    };
    _ = try createPackage(gpa, std.testing.io, .{
        .metadata = metadata,
        .target = .ios,
        .output_path = root ++ "/demo-ios",
        .assets_dir = root ++ "/assets",
    });

    const contents = try readPath(gpa, std.testing.io, root ++ "/demo-ios/Assets.xcassets/AppIcon.appiconset/Contents.json");
    defer gpa.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "1024x1024") != null);
    const icon = try readPath(gpa, std.testing.io, root ++ "/demo-ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png");
    defer gpa.free(icon);
    const header = app_icon_tool.pngHeader(icon) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(app_icon_tool.ios_icon_size, header.width);
}

test "android artifact carries launcher mipmaps and references them" {
    const gpa = std.testing.allocator;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-package-icon-android";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    try writeTestIconSource(gpa, std.testing.io, root ++ "/assets/icon.png", 64);

    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.app",
        .name = "demo",
        .version = "1.0.0",
        .icons = &.{root ++ "/assets/icon.png"},
    };
    _ = try createPackage(gpa, std.testing.io, .{
        .metadata = metadata,
        .target = .android,
        .output_path = root ++ "/demo-android",
        .assets_dir = root ++ "/assets",
    });

    inline for (app_icon_tool.android_densities) |density| {
        const icon_path = try std.fmt.allocPrint(gpa, "{s}/demo-android/res/mipmap-{s}/ic_launcher.png", .{ root, density.name });
        defer gpa.free(icon_path);
        const encoded = try readPath(gpa, std.testing.io, icon_path);
        defer gpa.free(encoded);
        const header = app_icon_tool.pngHeader(encoded) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, density.size), header.width);
    }
    const manifest = try readPath(gpa, std.testing.io, root ++ "/demo-android/AndroidManifest.xml");
    defer gpa.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "android:icon=\"@mipmap/ic_launcher\"") != null);
}
