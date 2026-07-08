//! The Android host tier: the toolkit owns the entire Android app.
//!
//! An app directory with app.zon + src/ never contains host code — the
//! Android host lives in the SDK (src/platform/android/, embedded into
//! the CLI below) and drives the app through the embed C ABI. Two
//! consumers:
//!
//! - `native dev --target android`: build the embed static library for
//!   aarch64-linux-android, assemble a debug APK around the toolkit
//!   host, install + launch it on a running (or freshly booted) emulator
//!   via `adb`, and stream the app log.
//! - `native package --target android` (package.zig): emit a complete
//!   generated host project around the same sources and assemble the
//!   debug APK when the Android toolchain is present.
//!
//! The APK assembles directly with the SDK's build tools (aapt2, javac,
//! d8, zipalign, apksigner) and the NDK compiler for the JNI bridge —
//! no build-system project, no plugin/version matrix, no wrapper
//! bootstrap. The host APK has exactly four inputs (generated manifest +
//! resources, one Java activity, one JNI library, bundled assets), all
//! derived from app.zon, so the direct tool pipeline is the entire
//! build; `native dev` and `native package` share it, which keeps the
//! two paths from drifting.
//!
//! Everything app-specific flows from app.zon: application id (`id`,
//! hyphens normalized to underscores for Java package grammar), names
//! (`name`/`display_name`), version, and icons (the shared single-source
//! icon pipeline renders the launcher mipmaps at package time).

const std = @import("std");
const builtin = @import("builtin");
const buildgraph = @import("buildgraph.zig");
const embedlib = @import("embedlib.zig");
const manifest_tool = @import("manifest.zig");
const process_tree = @import("process_tree.zig");
const toolchain = @import("toolchain.zig");

/// The toolkit-owned Android host application (canvas surface view,
/// touch/keyboard/IME forwarding, Paint text measurement, safe-area and
/// keyboard viewport reporting) — the single source of truth compiled by
/// both the dev loop and the packaged host project. The bytes arrive
/// through the `android_host` module (src/platform/android/files.zig).
pub const host_activity_source = @import("android_host").activity_java;
pub const host_bridge_source = @import("android_host").android_host_c;
pub const host_header = @import("android_host").native_sdk_app_h;

pub const host_activity_name = "NativeSdkActivity.java";
pub const host_bridge_name = "android_host.c";
pub const host_header_name = "native_sdk_app.h";

/// The host activity's fixed class; app identity comes from the
/// manifest's application id, not the Java namespace.
pub const host_activity_class = "dev.native_sdk.host.NativeSdkActivity";

/// minSdk 30 (Android 11): the first release with the WindowInsets
/// keyboard/cutout API surface the host's edge-to-edge inset reporting
/// is built on.
pub const min_sdk_version = "30";
pub const target_sdk_version = "35";

/// The embed library target. 64-bit Arm covers every Android 11+ device
/// and the emulator on Apple hosts; more ABIs are a packaging matrix
/// decision for a later round.
pub const zig_triple = "aarch64-linux-android";
pub const clang_target = "aarch64-linux-android" ++ min_sdk_version;
pub const apk_abi = "arm64-v8a";

pub const Error = error{
    MissingManifest,
    MissingFramework,
    MissingAndroidToolchain,
    MissingJava,
    ZigBuildFailed,
    HostCompileFailed,
    ApkAssemblyFailed,
    DeviceUnavailable,
    AdbCommandFailed,
};

/// Write the host sources into `dir_path` (created if needed).
pub fn writeHostSources(io: std.Io, dir_path: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = host_activity_name, .data = host_activity_source });
    try dir.writeFile(io, .{ .sub_path = host_bridge_name, .data = host_bridge_source });
    try dir.writeFile(io, .{ .sub_path = host_header_name, .data = host_header });
}

/// The Android application id for an app.zon `id`: Java package grammar
/// wants dot-separated identifiers (letters, digits, underscores;
/// letter-leading segments), so hyphens and other punctuation map to
/// underscores and non-letter-leading segments gain an `a` prefix — the
/// mirror of the iOS underscore-to-hyphen mapping.
pub fn applicationIdAlloc(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
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

/// The host-tier AndroidManifest.xml: app identity from app.zon plus the
/// fixed host activity. `configChanges` keeps the activity (and the
/// embedded runtime) alive across rotation and keyboard transitions —
/// they arrive as viewport resizes, not activity restarts. The manifest
/// stays debuggable: this tier assembles debug-signed APKs (store
/// distribution keys stay a manual step, like macOS notarization), and
/// debuggable is what lets `adb shell run-as` read the automation
/// snapshots.
pub fn manifestAlloc(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata, has_launcher_icon: bool) ![]u8 {
    const raw_application_id = try applicationIdAlloc(allocator, metadata.id);
    defer allocator.free(raw_application_id);
    const application_id = try xmlEscapeAlloc(allocator, raw_application_id);
    defer allocator.free(application_id);
    const label = try xmlEscapeAlloc(allocator, metadata.displayName());
    defer allocator.free(label);
    const version = try xmlEscapeAlloc(allocator, metadata.version);
    defer allocator.free(version);
    const icon_attribute: []const u8 = if (has_launcher_icon) " android:icon=\"@mipmap/ic_launcher\"" else "";
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{s}" android:versionCode="1" android:versionName="{s}">
        \\  <uses-permission android:name="android.permission.INTERNET" />
        \\  <application android:label="{s}"{s} android:debuggable="true" android:extractNativeLibs="true" android:networkSecurityConfig="@xml/network_security_config" android:theme="@android:style/Theme.Material.NoActionBar">
        \\    <activity android:name="
    ++ host_activity_class ++
        \\" android:exported="true" android:configChanges="keyboard|keyboardHidden|orientation|screenSize|smallestScreenSize|screenLayout|density|uiMode" android:windowSoftInputMode="adjustResize">
        \\      <intent-filter>
        \\        <action android:name="android.intent.action.MAIN" />
        \\        <category android:name="android.intent.category.LAUNCHER" />
        \\      </intent-filter>
        \\    </activity>
        \\  </application>
        \\</manifest>
        \\
    , .{ application_id, version, label, icon_attribute });
}

/// The manifest-referenced network security policy (`res/xml/`): TLS
/// stays required for everything on the internet, with cleartext HTTP
/// scoped to loopback and the emulator's host alias only — the dev loop
/// streams audio and other media from a server on the development
/// machine (which the emulator reaches at 10.0.2.2). The Android mirror
/// of the iOS host's local-networking-only transport exception.
pub const network_security_config_name = "network_security_config.xml";
pub const network_security_config =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<network-security-config>
    \\  <base-config cleartextTrafficPermitted="false" />
    \\  <domain-config cleartextTrafficPermitted="true">
    \\    <domain includeSubdomains="false">localhost</domain>
    \\    <domain includeSubdomains="false">127.0.0.1</domain>
    \\    <domain includeSubdomains="false">10.0.2.2</domain>
    \\  </domain-config>
    \\</network-security-config>
    \\
;

/// Write the fixed host resources (the network security config the
/// manifest references) into `res_dir`, preserving whatever else the
/// caller already staged there (launcher mipmaps in the package path).
pub fn writeHostResources(io: std.Io, res_dir: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const xml_dir = try std.fmt.bufPrint(&buffer, "{s}/xml", .{res_dir});
    try cwd.createDirPath(io, xml_dir);
    var dir = try cwd.openDir(io, xml_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = network_security_config_name, .data = network_security_config });
}

// ---------------------------------------------------------------- toolchain

/// The Android toolchain pieces the host tier drives directly. All paths
/// are absolute and allocator-owned.
pub const Toolchain = struct {
    sdk_root: []const u8,
    aapt: []const u8,
    aapt2: []const u8,
    zipalign: []const u8,
    d8_jar: []const u8,
    apksigner_jar: []const u8,
    android_jar: []const u8,
    ndk_clang: []const u8,
    adb: []const u8,
    emulator: []const u8,

    pub fn deinit(self: *const Toolchain, allocator: std.mem.Allocator) void {
        allocator.free(self.sdk_root);
        allocator.free(self.aapt);
        allocator.free(self.aapt2);
        allocator.free(self.zipalign);
        allocator.free(self.d8_jar);
        allocator.free(self.apksigner_jar);
        allocator.free(self.android_jar);
        allocator.free(self.ndk_clang);
        allocator.free(self.adb);
        allocator.free(self.emulator);
    }
};

/// Locate the Android SDK root: ANDROID_HOME, then ANDROID_SDK_ROOT,
/// then the platform-conventional install location.
pub fn sdkRootAlloc(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) !?[]const u8 {
    if (env_map.get("ANDROID_HOME")) |root| {
        if (root.len > 0) return try allocator.dupe(u8, root);
    }
    if (env_map.get("ANDROID_SDK_ROOT")) |root| {
        if (root.len > 0) return try allocator.dupe(u8, root);
    }
    switch (builtin.os.tag) {
        .macos => {
            const home = env_map.get("HOME") orelse return null;
            return try std.fs.path.join(allocator, &.{ home, "Library", "Android", "sdk" });
        },
        .windows => {
            const home = env_map.get("LOCALAPPDATA") orelse return null;
            return try std.fs.path.join(allocator, &.{ home, "Android", "Sdk" });
        },
        else => {
            const home = env_map.get("HOME") orelse return null;
            return try std.fs.path.join(allocator, &.{ home, "Android", "Sdk" });
        },
    }
}

/// Discover the full toolchain under the SDK root, or explain exactly
/// which piece is missing. Version directories (build-tools, platforms,
/// ndk) pick the highest installed version.
pub fn findToolchain(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !?Toolchain {
    const sdk_root = (try sdkRootAlloc(allocator, env_map)) orelse {
        printToolchainGuidance("no Android SDK location (set ANDROID_HOME)");
        return null;
    };
    errdefer allocator.free(sdk_root);
    if (!dirExists(io, sdk_root)) {
        std.debug.print("native (android): no Android SDK at {s}\n", .{sdk_root});
        printToolchainGuidance("the SDK root does not exist");
        allocator.free(sdk_root);
        return null;
    }

    const build_tools = try latestVersionSubdirAlloc(allocator, io, sdk_root, "build-tools", "") orelse {
        printToolchainGuidance("build-tools is not installed (sdkmanager \"build-tools;35.0.0\")");
        allocator.free(sdk_root);
        return null;
    };
    defer allocator.free(build_tools);
    const platform_dir = try latestVersionSubdirAlloc(allocator, io, sdk_root, "platforms", "android-") orelse {
        printToolchainGuidance("no platform is installed (sdkmanager \"platforms;android-35\")");
        allocator.free(sdk_root);
        return null;
    };
    defer allocator.free(platform_dir);
    const ndk_dir = try latestVersionSubdirAlloc(allocator, io, sdk_root, "ndk", "") orelse {
        printToolchainGuidance("the NDK is not installed (sdkmanager \"ndk;27.2.12479018\") - it links the JNI host library against bionic");
        allocator.free(sdk_root);
        return null;
    };
    defer allocator.free(ndk_dir);
    const ndk_clang = (try ndkClangAlloc(allocator, io, ndk_dir)) orelse {
        std.debug.print("native (android): the NDK at {s} has no llvm toolchain\n", .{ndk_dir});
        allocator.free(sdk_root);
        return null;
    };
    errdefer allocator.free(ndk_clang);

    const aapt = try std.fs.path.join(allocator, &.{ build_tools, exeName("aapt") });
    errdefer allocator.free(aapt);
    const aapt2 = try std.fs.path.join(allocator, &.{ build_tools, exeName("aapt2") });
    errdefer allocator.free(aapt2);
    const zipalign = try std.fs.path.join(allocator, &.{ build_tools, exeName("zipalign") });
    errdefer allocator.free(zipalign);
    const d8_jar = try std.fs.path.join(allocator, &.{ build_tools, "lib", "d8.jar" });
    errdefer allocator.free(d8_jar);
    const apksigner_jar = try std.fs.path.join(allocator, &.{ build_tools, "lib", "apksigner.jar" });
    errdefer allocator.free(apksigner_jar);
    const android_jar = try std.fs.path.join(allocator, &.{ platform_dir, "android.jar" });
    errdefer allocator.free(android_jar);
    const adb = try std.fs.path.join(allocator, &.{ sdk_root, "platform-tools", exeName("adb") });
    errdefer allocator.free(adb);
    const emulator = try std.fs.path.join(allocator, &.{ sdk_root, "emulator", exeName("emulator") });
    errdefer allocator.free(emulator);

    for ([_][]const u8{ aapt, aapt2, zipalign, d8_jar, apksigner_jar, android_jar }) |path| {
        if (!buildgraph.fileExists(io, path)) {
            std.debug.print("native (android): missing {s}\n", .{path});
            printToolchainGuidance("the installed build-tools/platform is incomplete");
            allocator.free(sdk_root);
            allocator.free(ndk_clang);
            allocator.free(aapt);
            allocator.free(aapt2);
            allocator.free(zipalign);
            allocator.free(d8_jar);
            allocator.free(apksigner_jar);
            allocator.free(android_jar);
            allocator.free(adb);
            allocator.free(emulator);
            return null;
        }
    }

    return .{
        .sdk_root = sdk_root,
        .aapt = aapt,
        .aapt2 = aapt2,
        .zipalign = zipalign,
        .d8_jar = d8_jar,
        .apksigner_jar = apksigner_jar,
        .android_jar = android_jar,
        .ndk_clang = ndk_clang,
        .adb = adb,
        .emulator = emulator,
    };
}

fn printToolchainGuidance(reason: []const u8) void {
    std.debug.print(
        \\native (android): the Android toolchain is unavailable: {s}.
        \\Install the command-line tools, then:
        \\  sdkmanager "platform-tools" "build-tools;35.0.0" "platforms;android-35" "ndk;27.2.12479018"
        \\and point ANDROID_HOME at the SDK root.
        \\
    , .{reason});
}

/// Resolve a JDK `java` binary: JAVA_HOME/bin/java, then the well-known
/// package-manager prefixes, then PATH. The build tools' dex compiler
/// and APK signer are JVM tools (invoked by explicit jar below), so a
/// JDK is a real dependency of the Android tier.
pub fn resolveJavaAlloc(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !?[]const u8 {
    if (env_map.get("JAVA_HOME")) |java_home| {
        if (java_home.len > 0) {
            const candidate = try std.fs.path.join(allocator, &.{ java_home, "bin", exeName("java") });
            if (buildgraph.fileExists(io, candidate)) return candidate;
            allocator.free(candidate);
        }
    }
    const well_known = [_][]const u8{
        "/opt/homebrew/opt/openjdk/bin/java",
        "/usr/local/opt/openjdk/bin/java",
    };
    for (well_known) |candidate| {
        if (buildgraph.fileExists(io, candidate)) return try allocator.dupe(u8, candidate);
    }
    // PATH fallback: verify it actually runs (macOS ships a stub at
    // /usr/bin/java that fails without an installed JDK).
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "java", "-version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) return try allocator.dupe(u8, "java");
    return null;
}

// ------------------------------------------------------------ embed library

pub const LibBuildOptions = struct {
    base_env: *std.process.Environ.Map,
    assume_yes: bool = false,
    forwarded_args: []const []const u8 = &.{},
    optimize: []const u8 = "Debug",
};

/// Build the app's embed static library via `zig build lib
/// -Dtarget=aarch64-linux-android` (the step `addApp`/`addMobileLib`
/// register for mobile targets), synthesizing the generated build graph
/// for non-ejected apps exactly like `native build`. Returns the
/// installed library path, allocator-owned. Expects the caller to have
/// chdir'd into the app dir.
///
/// The install prefix is keyed by the target triple
/// (.native/embed/aarch64-linux-android): the iOS slices build the same
/// `lib` step for other targets, and a single shared destination let
/// whichever slice built last own the bytes — a Mach-O archive in the
/// Android slot then linked *silently* into the host .so (a `-shared`
/// link tolerates undefined symbols) and only failed at dlopen on the
/// device. A private per-triple stage makes cross-target runs unable to
/// clobber each other; content freshness within the stage is the
/// compiler's content-addressed cache, never wall-clock time.
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
    const prefix = try embedlib.prefixAlloc(allocator, cwd_path, zig_triple);
    defer allocator.free(prefix);
    try argv.appendSlice(allocator, &.{ "--prefix", prefix });

    try argv.append(allocator, "-Dtarget=" ++ zig_triple);
    const optimize_flag = try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{options.optimize});
    defer allocator.free(optimize_flag);
    if (!hasOptimizeFlag(options.forwarded_args)) try argv.append(allocator, optimize_flag);
    try argv.appendSlice(allocator, options.forwarded_args);

    try runInherit(io, argv.items, error.ZigBuildFailed);

    const lib_path = try embedlib.libPathAlloc(allocator, zig_triple, app_name);
    errdefer allocator.free(lib_path);
    if (!buildgraph.fileExists(io, lib_path)) {
        std.debug.print("native: expected the embed library at {s} after `zig build lib` - the app build did not install it\n", .{lib_path});
        return error.ZigBuildFailed;
    }
    return lib_path;
}

/// Compile and link the JNI host library (android_host.c + the embed
/// static library) into `out_so` with the NDK compiler — the only
/// toolchain that can link bionic. The max-page-size link flag keeps the
/// library loadable on 16 KB page devices.
///
/// Two honesty guards around the link: the staged embed archive must
/// actually be ELF AArch64 (an archive built for another target has a
/// symbol index that never matches, so the linker pulls nothing and
/// only warns), and `--no-undefined` turns any dangling reference into
/// a build-time failure here instead of an UnsatisfiedLinkError at
/// dlopen on the device.
pub fn compileHostLibrary(allocator: std.mem.Allocator, io: std.Io, tc: *const Toolchain, host_dir: []const u8, lib_path: []const u8, out_so: []const u8) !void {
    embedlib.requireArchiveClass(allocator, io, lib_path, .elf_aarch64, zig_triple) catch return error.HostCompileFailed;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const bridge_path = try std.fmt.bufPrint(&buffer, "{s}/" ++ host_bridge_name, .{host_dir});
    try runInherit(io, &.{
        tc.ndk_clang,
        "--target=" ++ clang_target,
        "-shared",
        "-O2",
        "-fPIC",
        "-Wl,-z,max-page-size=16384",
        "-Wl,--no-undefined",
        bridge_path,
        lib_path,
        "-landroid",
        "-llog",
        // The embed library references libm/libdl symbols; bionic splits
        // them out, and the NDK driver does not add them for -shared.
        "-lm",
        "-ldl",
        "-o",
        out_so,
    }, error.HostCompileFailed);
}

// ------------------------------------------------------------ apk assembly

pub const ApkOptions = struct {
    toolchain: *const Toolchain,
    java: []const u8,
    /// Recreated staging directory for compile/dex/link intermediates.
    work_dir: []const u8,
    manifest_path: []const u8,
    /// Directory of host .java sources (host_activity_name inside it).
    host_dir: []const u8,
    /// The compiled JNI host library to place at lib/<abi>/.
    so_path: []const u8,
    /// Optional res/ directory (launcher mipmaps) compiled into the APK.
    res_dir: ?[]const u8 = null,
    /// Optional directory whose contents land under assets/native-sdk.
    assets_dir: ?[]const u8 = null,
    keystore_path: []const u8,
    out_apk: []const u8,
};

/// Assemble and debug-sign the host APK with the SDK build tools:
/// javac -> d8 (dex), aapt2 (resources + manifest), aapt (dex, JNI
/// library, and asset entries), zipalign, apksigner.
pub fn assembleApk(allocator: std.mem.Allocator, io: std.Io, options: ApkOptions) !void {
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, options.work_dir) catch {};
    const classes_dir = try std.fs.path.join(allocator, &.{ options.work_dir, "classes" });
    defer allocator.free(classes_dir);
    const root_dir = try std.fs.path.join(allocator, &.{ options.work_dir, "apk" });
    defer allocator.free(root_dir);
    try cwd.createDirPath(io, classes_dir);
    try cwd.createDirPath(io, root_dir);

    // Host activity -> JVM classes. --release pins the Java platform
    // surface; the Android APIs come from the platform android.jar.
    const activity_path = try std.fs.path.join(allocator, &.{ options.host_dir, host_activity_name });
    defer allocator.free(activity_path);
    const javac = try javaSiblingAlloc(allocator, options.java, "javac");
    defer allocator.free(javac);
    try runInherit(io, &.{
        javac,          "--release", "17",       "-encoding",
        "UTF-8",        "-cp",       options.toolchain.android_jar, "-d",
        classes_dir,    activity_path,
    }, error.ApkAssemblyFailed);

    // Classes -> classes.dex at the APK root.
    var dex_argv: std.ArrayList([]const u8) = .empty;
    defer dex_argv.deinit(allocator);
    try dex_argv.appendSlice(allocator, &.{
        options.java, "-cp",      options.toolchain.d8_jar, "com.android.tools.r8.D8",
        "--release",  "--lib",    options.toolchain.android_jar,
        "--min-api",  min_sdk_version, "--output", root_dir,
    });
    var class_files = try collectFilesAlloc(allocator, io, classes_dir, ".class");
    defer freePathList(allocator, &class_files);
    if (class_files.items.len == 0) return error.ApkAssemblyFailed;
    try dex_argv.appendSlice(allocator, class_files.items);
    try runInherit(io, dex_argv.items, error.ApkAssemblyFailed);

    // The JNI host library and bundled assets in their APK-root layout.
    const so_dest = try std.fs.path.join(allocator, &.{ root_dir, "lib", apk_abi, "libnative_sdk_host.so" });
    defer allocator.free(so_dest);
    try copyFilePath(allocator, io, options.so_path, so_dest);
    if (options.assets_dir) |assets_dir| {
        const assets_dest = try std.fs.path.join(allocator, &.{ root_dir, "assets", "native-sdk" });
        defer allocator.free(assets_dest);
        try copyTree(allocator, io, assets_dir, assets_dest);
    }

    // Resources + manifest -> the base APK.
    const unaligned = try std.fs.path.join(allocator, &.{ options.work_dir, "unaligned.apk" });
    defer allocator.free(unaligned);
    var res_zip: ?[]const u8 = null;
    defer if (res_zip) |path| allocator.free(path);
    if (options.res_dir) |res_dir| {
        const compiled = try std.fs.path.join(allocator, &.{ options.work_dir, "res.zip" });
        try runInherit(io, &.{ options.toolchain.aapt2, "compile", "--dir", res_dir, "-o", compiled }, error.ApkAssemblyFailed);
        res_zip = compiled;
    }
    var link_argv: std.ArrayList([]const u8) = .empty;
    defer link_argv.deinit(allocator);
    try link_argv.appendSlice(allocator, &.{
        options.toolchain.aapt2, "link",
        "-o",                    unaligned,
        "--manifest",            options.manifest_path,
        "-I",                    options.toolchain.android_jar,
        "--min-sdk-version",     min_sdk_version,
        "--target-sdk-version",  target_sdk_version,
    });
    if (res_zip) |path| try link_argv.append(allocator, path);
    try runInherit(io, link_argv.items, error.ApkAssemblyFailed);

    // classes.dex, the JNI library, and assets enter the APK with their
    // in-archive names, so aapt runs from the staged APK root.
    var add_argv: std.ArrayList([]const u8) = .empty;
    defer add_argv.deinit(allocator);
    const unaligned_abs = try absolutePathAlloc(allocator, io, unaligned);
    defer allocator.free(unaligned_abs);
    try add_argv.appendSlice(allocator, &.{ options.toolchain.aapt, "add", unaligned_abs });
    var payload_files = try collectFilesAlloc(allocator, io, root_dir, "");
    defer freePathList(allocator, &payload_files);
    var relative_paths: std.ArrayList([]const u8) = .empty;
    defer freePathList(allocator, &relative_paths);
    for (payload_files.items) |path| {
        const relative = path[root_dir.len + 1 ..];
        try relative_paths.append(allocator, try allocator.dupe(u8, relative));
    }
    if (relative_paths.items.len == 0) return error.ApkAssemblyFailed;
    try add_argv.appendSlice(allocator, relative_paths.items);
    try runInheritCwd(io, add_argv.items, root_dir, error.ApkAssemblyFailed);

    const aligned = try std.fs.path.join(allocator, &.{ options.work_dir, "aligned.apk" });
    defer allocator.free(aligned);
    try runInherit(io, &.{ options.toolchain.zipalign, "-f", "4", unaligned, aligned }, error.ApkAssemblyFailed);

    try ensureDebugKeystore(allocator, io, options.java, options.keystore_path);
    try runInherit(io, &.{
        options.java,           "-jar",           options.toolchain.apksigner_jar, "sign",
        "--ks",                 options.keystore_path,
        "--ks-pass",            "pass:android",
        "--ks-key-alias",       "native-sdk-debug",
        "--out",                options.out_apk,
        aligned,
    }, error.ApkAssemblyFailed);
}

/// The debug signing keystore under the durable per-user toolkit state
/// directory (~/.native/android). Generated once with the JDK's keytool;
/// debug keys identify a development install, nothing more.
pub fn debugKeystorePathAlloc(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) ![]const u8 {
    const home = env_map.get("HOME") orelse env_map.get("USERPROFILE") orelse return error.MissingJava;
    return std.fs.path.join(allocator, &.{ home, ".native", "android", "debug.keystore" });
}

fn ensureDebugKeystore(allocator: std.mem.Allocator, io: std.Io, java: []const u8, keystore_path: []const u8) !void {
    if (buildgraph.fileExists(io, keystore_path)) return;
    var cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(keystore_path)) |dir| try cwd.createDirPath(io, dir);
    const keytool = try javaSiblingAlloc(allocator, java, "keytool");
    defer allocator.free(keytool);
    std.debug.print("native (android): generating the debug signing keystore at {s}\n", .{keystore_path});
    try runInherit(io, &.{
        keytool,      "-genkeypair", "-keystore", keystore_path,
        "-storepass", "android",     "-keypass",  "android",
        "-alias",     "native-sdk-debug",
        "-keyalg",    "RSA",         "-keysize",  "2048",
        "-validity",  "10950",       "-dname",    "CN=Native SDK Debug",
    }, error.ApkAssemblyFailed);
}

// ------------------------------------------------------------------ dev loop

pub const DevOptions = struct {
    base_env: *std.process.Environ.Map,
    assume_yes: bool = false,
    forwarded_args: []const []const u8 = &.{},
    /// adb device serial or AVD name (`--device`); picked automatically
    /// when unset (a running device, else the first available AVD is
    /// booted).
    device: ?[]const u8 = null,
};

/// `native dev --target android`: build the embed library, assemble the
/// debug APK around the toolkit host, install + launch it on an emulator
/// (or attached device) via adb, and stream the app log until Ctrl-C.
///
/// Markup fragment hot reload is not wired to the device yet: the
/// watcher polls source paths relative to the app process's working
/// directory through an Io the desktop runner supplies, and the embed
/// host supplies neither — edit + rerun is the loop today.
pub fn runDev(allocator: std.mem.Allocator, io: std.Io, options: DevOptions) !void {
    if (!buildgraph.fileExists(io, "app.zon")) {
        std.debug.print(
            \\no app.zon here — `native dev --target android` runs inside an app directory
            \\(or pass one: `native dev path/to/app --target android`). Start one with `native init`.
            \\
        , .{});
        return error.MissingManifest;
    }
    const metadata = try manifest_tool.readMetadata(allocator, io, "app.zon");
    const application_id = try applicationIdAlloc(allocator, metadata.id);
    defer allocator.free(application_id);

    const tc = (try findToolchain(allocator, io, options.base_env)) orelse return error.MissingAndroidToolchain;
    defer tc.deinit(allocator);
    const java = (try resolveJavaAlloc(allocator, io, options.base_env)) orelse {
        std.debug.print("native dev (android): no JDK found - set JAVA_HOME (the dex compiler and APK signer are JVM tools)\n", .{});
        return error.MissingJava;
    };
    defer allocator.free(java);

    std.debug.print("native dev (android): building the embed library ({s}, Debug)\n", .{zig_triple});
    const lib_path = try buildEmbedLib(allocator, io, metadata.name, .{
        .base_env = options.base_env,
        .assume_yes = options.assume_yes,
        .forwarded_args = options.forwarded_args,
    });
    defer allocator.free(lib_path);

    // Assemble the debug APK around the toolkit host.
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, ".native/android");
    try writeHostSources(io, ".native/android/host");
    try writeHostResources(io, ".native/android/res");
    const manifest_text = try manifestAlloc(allocator, metadata, false);
    defer allocator.free(manifest_text);
    {
        var dir = try cwd.openDir(io, ".native/android", .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "AndroidManifest.xml", .data = manifest_text });
    }

    std.debug.print("native dev (android): compiling the toolkit host library ({s})\n", .{clang_target});
    try compileHostLibrary(allocator, io, &tc, ".native/android/host", lib_path, ".native/android/libnative_sdk_host.so");

    const apk_path = try std.fmt.allocPrint(allocator, ".native/android/{s}-debug.apk", .{metadata.name});
    defer allocator.free(apk_path);
    const keystore_path = try debugKeystorePathAlloc(allocator, options.base_env);
    defer allocator.free(keystore_path);
    std.debug.print("native dev (android): assembling {s}\n", .{apk_path});
    try assembleApk(allocator, io, .{
        .toolchain = &tc,
        .java = java,
        .work_dir = ".native/android/build",
        .manifest_path = ".native/android/AndroidManifest.xml",
        .host_dir = ".native/android/host",
        .so_path = ".native/android/libnative_sdk_host.so",
        .res_dir = ".native/android/res",
        .assets_dir = if (dirExists(io, "assets")) "assets" else null,
        .keystore_path = keystore_path,
        .out_apk = apk_path,
    });

    const serial = try ensureDevice(allocator, io, &tc, options.device);
    defer allocator.free(serial);

    std.debug.print("native dev (android): installing {s} ({s}) on {s}\n", .{ apk_path, application_id, serial });
    try runInherit(io, &.{ tc.adb, "-s", serial, "install", "-r", apk_path }, error.AdbCommandFailed);
    runQuiet(allocator, io, &.{ tc.adb, "-s", serial, "shell", "am", "force-stop", application_id }) catch {};

    const component = try std.fmt.allocPrint(allocator, "{s}/" ++ host_activity_class, .{application_id});
    defer allocator.free(component);
    std.debug.print(
        \\native dev (android): launching {s} — streaming the app log (Ctrl-C stops it).
        \\  markup hot reload does not reach the device yet: edit, then rerun `native dev --target android`.
        \\
    , .{application_id});
    try runInherit(io, &.{ tc.adb, "-s", serial, "shell", "am", "start", "-n", component }, error.AdbCommandFailed);

    // The log stream: the host logs under the native-sdk tag, crashes
    // land under AndroidRuntime. The child gets its own process group so
    // Ctrl-C/kill of the CLI also stops the stream.
    var logcat_child = try std.process.spawn(io, .{
        .argv = &.{ tc.adb, "-s", serial, "logcat", "-T", "1", "-s", "native-sdk:V", "AndroidRuntime:E" },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .pgid = process_tree.spawnPgid(),
    });
    const logcat_group: i32 = process_tree.groupId(&logcat_child);
    if (logcat_group > 0) process_tree.own(logcat_group);
    defer if (logcat_group > 0) process_tree.releaseAndKill(logcat_group);
    _ = try logcat_child.wait(io);
}

/// Pick a device serial: a running device wins (or the one `--device`
/// names); otherwise boot the requested (or first available) AVD and
/// wait for it.
fn ensureDevice(allocator: std.mem.Allocator, io: std.Io, tc: *const Toolchain, requested: ?[]const u8) ![]const u8 {
    const listing = try runCaptureStdout(allocator, io, &.{ tc.adb, "devices" }, error.AdbCommandFailed);
    defer allocator.free(listing);
    if (parseAdbDeviceList(listing, requested)) |serial| {
        return allocator.dupe(u8, serial);
    }
    if (requested) |name| {
        // Not a running serial: treat it as an AVD name to boot.
        return bootEmulator(allocator, io, tc, name);
    }
    const avds = try runCaptureStdout(allocator, io, &.{ tc.emulator, "-list-avds" }, error.DeviceUnavailable);
    defer allocator.free(avds);
    const first_avd = firstNonEmptyLine(avds) orelse {
        std.debug.print(
            \\native dev (android): no running device and no emulator image (AVD) to boot.
            \\Create one, then rerun:
            \\  avdmanager create avd --name native-sdk --package "system-images;android-35;google_apis;arm64-v8a"
            \\
        , .{});
        return error.DeviceUnavailable;
    };
    return bootEmulator(allocator, io, tc, first_avd);
}

/// Boot an AVD headfully and wait for the OS to finish booting. The
/// emulator process lives in the dev session's process group, so it ends
/// with the session.
fn bootEmulator(allocator: std.mem.Allocator, io: std.Io, tc: *const Toolchain, avd_name: []const u8) ![]const u8 {
    std.debug.print("native dev (android): booting emulator \"{s}\"\n", .{avd_name});
    // The emulator outlives this function but stays in the dev session's
    // process group, so it ends with the session; its exit is reaped by
    // the OS when the CLI exits (the Child handle is intentionally not
    // awaited).
    var child = try std.process.spawn(io, .{
        .argv = &.{ tc.emulator, "-avd", avd_name, "-no-snapshot-save", "-no-boot-anim" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = &child;

    // Wait for the freshly booted emulator to appear and finish booting
    // (`sys.boot_completed`), up to three minutes.
    var attempt: usize = 0;
    while (attempt < 180) : (attempt += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
        const listing = runCaptureStdout(allocator, io, &.{ tc.adb, "devices" }, error.AdbCommandFailed) catch continue;
        defer allocator.free(listing);
        const serial = parseAdbDeviceList(listing, null) orelse continue;
        const booted = runCaptureStdout(allocator, io, &.{ tc.adb, "-s", serial, "shell", "getprop", "sys.boot_completed" }, error.AdbCommandFailed) catch continue;
        defer allocator.free(booted);
        if (std.mem.indexOfScalar(u8, booted, '1') != null) {
            return allocator.dupe(u8, serial);
        }
    }
    std.debug.print("native dev (android): the emulator did not finish booting within three minutes\n", .{});
    return error.DeviceUnavailable;
}

/// `adb devices` lines look like `emulator-5554\tdevice`; return the
/// requested serial when it is attached and ready, else the first ready
/// device.
pub fn parseAdbDeviceList(listing: []const u8, requested: ?[]const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    var first: ?[]const u8 = null;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "List of devices")) continue;
        const tab = std.mem.indexOfScalar(u8, trimmed, '\t') orelse continue;
        const serial = trimmed[0..tab];
        const state = std.mem.trim(u8, trimmed[tab + 1 ..], " \t");
        if (!std.mem.eql(u8, state, "device")) continue;
        if (requested) |want| {
            if (std.mem.eql(u8, serial, want)) return serial;
        } else if (first == null) {
            first = serial;
        }
    }
    if (requested != null) return null;
    return first;
}

pub fn hasOptimizeFlag(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-Doptimize")) return true;
        if (std.mem.startsWith(u8, arg, "--release")) return true;
    }
    return false;
}

// ------------------------------------------------------------------ helpers

fn exeName(comptime name: []const u8) []const u8 {
    return if (builtin.os.tag == .windows) name ++ ".exe" else name;
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// A JDK tool next to the resolved `java` binary (javac, keytool). A
/// bare `java` from PATH keeps the sibling on PATH too.
fn javaSiblingAlloc(allocator: std.mem.Allocator, java: []const u8, tool: []const u8) ![]const u8 {
    if (std.fs.path.dirname(java)) |dir| {
        return std.fs.path.join(allocator, &.{ dir, tool });
    }
    return allocator.dupe(u8, tool);
}

/// The version-highest subdirectory of `root/parent` whose name starts
/// with `prefix` (numeric segment comparison, so 35.0.0 > 9.0.0), as an
/// absolute joined path.
fn latestVersionSubdirAlloc(allocator: std.mem.Allocator, io: std.Io, root: []const u8, parent: []const u8, prefix: []const u8) !?[]const u8 {
    const parent_path = try std.fs.path.join(allocator, &.{ root, parent });
    defer allocator.free(parent_path);
    var cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, parent_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var best: ?[]const u8 = null;
    errdefer if (best) |value| allocator.free(value);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        const version = entry.name[prefix.len..];
        if (best) |current| {
            const current_version = std.fs.path.basename(current)[prefix.len..];
            if (!versionLess(current_version, version)) continue;
            allocator.free(current);
            best = null;
        }
        best = try std.fs.path.join(allocator, &.{ parent_path, entry.name });
    }
    return best;
}

/// Numeric-segment version ordering: "9.0.0" < "35.0.0", non-numeric
/// tails compare lexically.
pub fn versionLess(a: []const u8, b: []const u8) bool {
    var a_parts = std.mem.splitScalar(u8, a, '.');
    var b_parts = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const a_part = a_parts.next();
        const b_part = b_parts.next();
        if (a_part == null and b_part == null) return false;
        if (a_part == null) return true;
        if (b_part == null) return false;
        const a_num = std.fmt.parseUnsigned(u64, a_part.?, 10) catch null;
        const b_num = std.fmt.parseUnsigned(u64, b_part.?, 10) catch null;
        if (a_num != null and b_num != null) {
            if (a_num.? != b_num.?) return a_num.? < b_num.?;
        } else {
            switch (std.mem.order(u8, a_part.?, b_part.?)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
        }
    }
}

/// The NDK's clang for the current host (the single llvm prebuilt the
/// NDK ships per platform).
fn ndkClangAlloc(allocator: std.mem.Allocator, io: std.Io, ndk_dir: []const u8) !?[]const u8 {
    const prebuilt_path = try std.fs.path.join(allocator, &.{ ndk_dir, "toolchains", "llvm", "prebuilt" });
    defer allocator.free(prebuilt_path);
    var cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, prebuilt_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const clang = try std.fs.path.join(allocator, &.{ prebuilt_path, entry.name, "bin", exeName("clang") });
        if (buildgraph.fileExists(io, clang)) return clang;
        allocator.free(clang);
    }
    return null;
}

/// Every regular file under `dir_path` (recursive) whose name ends with
/// `suffix` (empty matches all), as joined paths.
fn collectFilesAlloc(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, suffix: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer freePathList(allocator, &out);
    var cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (suffix.len > 0 and !std.mem.endsWith(u8, entry.path, suffix)) continue;
        try out.append(allocator, try std.fs.path.join(allocator, &.{ dir_path, entry.path }));
    }
    std.mem.sort([]const u8, out.items, {}, pathLess);
    return out;
}

fn pathLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn freePathList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |path| allocator.free(path);
    list.deinit(allocator);
}

fn copyFilePath(allocator: std.mem.Allocator, io: std.Io, source: []const u8, dest: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(dest)) |dir| try cwd.createDirPath(io, dir);
    var file = try cwd.openFile(io, source, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024 * 1024));
    defer allocator.free(bytes);
    try cwd.writeFile(io, .{ .sub_path = dest, .data = bytes });
}

fn copyTree(allocator: std.mem.Allocator, io: std.Io, source_dir: []const u8, dest_dir: []const u8) !void {
    var files = try collectFilesAlloc(allocator, io, source_dir, "");
    defer freePathList(allocator, &files);
    for (files.items) |path| {
        const relative = path[source_dir.len + 1 ..];
        const dest = try std.fs.path.join(allocator, &.{ dest_dir, relative });
        defer allocator.free(dest);
        try copyFilePath(allocator, io, path, dest);
    }
}

fn firstNonEmptyLine(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        // The emulator prints INFO chatter before the AVD list on some
        // installs; AVD names never contain '|' or ':'.
        if (std.mem.indexOfAny(u8, trimmed, "|:") != null) continue;
        return trimmed;
    }
    return null;
}

fn absolutePathAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    return std.fs.path.join(allocator, &.{ cwd_path, path });
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
    std.debug.print("native (android): `{s}` step failed\n", .{argv[0]});
    return fail_error;
}

fn runInheritCwd(io: std.Io, argv: []const []const u8, cwd_path: []const u8, fail_error: anyerror) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd_path },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("native (android): `{s}` step failed\n", .{argv[0]});
    return fail_error;
}

/// Run capturing stdout; non-zero exit becomes `fail_error`.
fn runCaptureStdout(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, fail_error: anyerror) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("native (android): `{s}` failed\n", .{argv[0]});
        return fail_error;
    }
    return result.stdout;
}

/// Run capturing (and discarding) output — for idempotent commands whose
/// failure chatter would only mislead (`am force-stop` before the first
/// install).
fn runQuiet(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.AdbCommandFailed;
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

test "application ids normalize hyphens for the Java package grammar" {
    const mapped = try applicationIdAlloc(std.testing.allocator, "dev.native-sdk.ui-inbox");
    defer std.testing.allocator.free(mapped);
    try std.testing.expectEqualStrings("dev.native_sdk.ui_inbox", mapped);

    const digit_led = try applicationIdAlloc(std.testing.allocator, "dev.7tools.app");
    defer std.testing.allocator.free(digit_led);
    try std.testing.expectEqualStrings("dev.a7tools.app", digit_led);
}

test "host manifest carries app identity, the host activity, and rotation survival" {
    const text = try manifestAlloc(std.testing.allocator, .{
        .id = "dev.native-sdk.calculator",
        .name = "calculator",
        .display_name = "Calculator <Pro>",
        .version = "0.2.0",
    }, true);
    defer std.testing.allocator.free(text);
    // The application id is normalized for Android (hyphen -> underscore).
    try std.testing.expect(std.mem.indexOf(u8, text, "package=\"dev.native_sdk.calculator\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "android:label=\"Calculator &lt;Pro&gt;\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "android:versionName=\"0.2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, host_activity_class) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "orientation|screenSize") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "android:windowSoftInputMode=\"adjustResize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@mipmap/ic_launcher") != null);
    // Networking for streamed audio (and other media): INTERNET plus the
    // security policy that scopes cleartext to local networking only.
    try std.testing.expect(std.mem.indexOf(u8, text, "android.permission.INTERNET") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "android:networkSecurityConfig=\"@xml/network_security_config\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, network_security_config, "cleartextTrafficPermitted=\"false\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, network_security_config, "10.0.2.2") != null);

    const bare = try manifestAlloc(std.testing.allocator, .{
        .id = "dev.native_sdk.hello",
        .name = "hello",
        .version = "0.1.0",
    }, false);
    defer std.testing.allocator.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "@mipmap/ic_launcher") == null);
}

test "the embedded host sources are the toolkit host" {
    try std.testing.expect(std.mem.indexOf(u8, host_activity_source, "package dev.native_sdk.host;") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_activity_source, "InputMethodManager") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_activity_source, "setComposingText") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_activity_source, "WindowInsets.Type.ime()") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_bridge_source, "native_sdk_app_render_pixels") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_bridge_source, "native_sdk_app_viewport") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_bridge_source, "native_sdk_app_ime") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_bridge_source, "ANativeWindow_unlockAndPost") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_header, "native_sdk_app_render_pixels") != null);
    // The audio service: registered before start, the MediaPlayer engine
    // with the parallel cache fill, audio focus, and the focus-loss
    // handler that pauses the transport and reports the paused state
    // through one immediate position event.
    try std.testing.expect(std.mem.indexOf(u8, host_activity_source, "nativeSetAudioService") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_activity_source, "MediaPlayer") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_activity_source, "AudioFocusRequest") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_activity_source, "onAudioFocusChange") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_activity_source, "startAudioCacheDownload") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_activity_source, "renameTo") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_bridge_source, "native_sdk_app_set_audio_service") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_bridge_source, "nativeAudioEvent") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_header, "native_sdk_audio_service_t") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_header, "native_sdk_app_audio_event") != null);
}

test "adb device parsing prefers ready devices and honors requests" {
    const listing = "List of devices attached\nemulator-5554\tdevice\nemulator-5556\toffline\n\n";
    try std.testing.expectEqualStrings("emulator-5554", parseAdbDeviceList(listing, null).?);
    try std.testing.expectEqualStrings("emulator-5554", parseAdbDeviceList(listing, "emulator-5554").?);
    try std.testing.expectEqual(@as(?[]const u8, null), parseAdbDeviceList(listing, "emulator-5556"));
    try std.testing.expectEqual(@as(?[]const u8, null), parseAdbDeviceList("List of devices attached\n\n", null));
}

test "version ordering compares numeric segments" {
    try std.testing.expect(versionLess("9.0.0", "35.0.0"));
    try std.testing.expect(!versionLess("35.0.0", "9.0.0"));
    try std.testing.expect(versionLess("27.1.1", "27.2.12479018"));
    try std.testing.expect(!versionLess("35", "35"));
}
