//! Zero-config build graph: when an app directory carries only app.zon +
//! src/ (+ assets), the CLI synthesizes a build.zig/build.zig.zon pair into
//! `<app>/.native/build/` and drives it with `zig build --build-file`. The
//! generated build.zig is the same ~5-line `addApp` call every ejected app
//! uses — build/app.zig in the framework stays the single source of truth
//! for module wiring and flags, so flag changes happen once there and both
//! generated and ejected apps pick them up.
//!
//! Location rationale (vs a ~/.native cache keyed by app path): Zig
//! resolves path dependencies and the local `.zig-cache` relative to the
//! build root, so an in-app `.native/build/` keeps the framework path
//! dependency correct when the app moves *and* keeps every derived artifact
//! (`.native/build/.zig-cache`) inside one gitignored directory that a user
//! can delete to fully reset. A home-dir cache keyed by absolute path would
//! leak stale graphs on rename and force absolute framework paths, which
//! build.zig.zon rejects.

const std = @import("std");
const templates = @import("templates.zig");
const junction = @import("junction.zig");

pub const generated_dir = ".native/build";

/// Where the cross-volume junction lives, relative to the app dir: a
/// directory junction `.native/sdk` -> framework root lets the generated
/// build graph reference an SDK on another Windows volume through a
/// relative zon path (`../sdk` from the `.native/build` build root), since
/// build.zig.zon rejects absolute paths and no `..` chain crosses volumes.
pub const sdk_junction_dir = ".native/sdk";
const junction_dependency_path = "../sdk";

pub const Error = error{
    MissingFramework,
    AlreadyEjected,
    CrossVolumeFramework,
};

/// How the framework path dependency reaches the zon file. Pure decision
/// over the `std.fs.path.relative` result, so the cross-volume case is
/// testable with fabricated drive-letter paths on every host.
pub const DependencyRoute = union(enum) {
    /// Same volume (or any non-Windows host): the computed relative path
    /// goes into the zon verbatim, exactly as before.
    relative: []const u8,
    /// The framework sits on another Windows volume, where no relative
    /// path exists: the zon gets `../sdk` and the caller must create or
    /// refresh the `.native/sdk` junction.
    junction,
};

pub fn routeDependencyPath(dependency_path: []const u8) DependencyRoute {
    if (junction.crossesVolumes(dependency_path)) return .junction;
    return .{ .relative = if (dependency_path.len == 0) "." else dependency_path };
}

/// The two user-level ways out when the junction bridge is unavailable
/// (appended to every cross-volume teaching error).
pub const cross_volume_ways_out = junction.cross_volume_ways_out;

/// Where the `native_sdk` framework checkout lives, for wiring the path
/// dependency of a generated or ejected build graph. Resolution order:
///   1. NATIVE_SDK_PATH environment variable (explicit override; the npm
///      wrapper sets it to the package that carries src/)
///   2. derived from the CLI executable location (frameworkRootFromExecutable)
/// Returns an absolute path, or null when neither resolves.
pub fn resolveFrameworkRoot(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !?[]const u8 {
    if (env_map.get("NATIVE_SDK_PATH")) |path| {
        if (path.len > 0 and hasFrameworkRoot(allocator, io, path)) {
            if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);
            // realPathFileAlloc returns a sentinel-terminated allocation
            // (length + 1 bytes); this function's contract is a plain
            // slice the caller frees, so re-dupe without the sentinel or
            // that free is off by one byte.
            const real_path = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
            defer allocator.free(real_path);
            return try allocator.dupe(u8, real_path);
        }
    }

    return frameworkRootFromExecutable(allocator, io);
}

/// Derive the framework root from the CLI executable's own location, so a
/// `native` binary is self-sufficient wherever it was installed from.
/// Layouts covered (binary path -> framework root):
///   - `<checkout>/zig-out/bin/native` -> `<checkout>` (source checkout)
///   - `<package>/bin/native` -> `<package>` (any bundle carrying src/
///     next to bin/)
///   - `node_modules/@native-sdk/cli-<platform>/bin/native` ->
///     `node_modules/@native-sdk/cli` (npm split install: per-platform
///     packages carry only the binary, the main package next to them
///     carries the SDK source — nested or hoisted/global node_modules)
/// The walk checks each of the four nearest ancestors, plus a `cli`
/// sibling at each level for the npm split shape, and accepts the first
/// directory that has `src/root.zig`.
pub fn frameworkRootFromExecutable(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_len = std.process.executablePath(io, &buffer) catch return null;
    const executable_path = buffer[0..executable_len];

    var dir: []const u8 = std.fs.path.dirname(executable_path) orelse return null;
    var level: usize = 0;
    while (level < 4) : (level += 1) {
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (hasFrameworkRoot(allocator, io, parent)) {
            return try allocator.dupe(u8, parent);
        }
        const sibling = try std.fs.path.join(allocator, &.{ parent, "cli" });
        if (hasFrameworkRoot(allocator, io, sibling)) return sibling;
        allocator.free(sibling);
        dir = parent;
    }
    return null;
}

pub fn hasFrameworkRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8) bool {
    const root_zig = std.fs.path.join(allocator, &.{ root, "src", "root.zig" }) catch return false;
    defer allocator.free(root_zig);
    var file = std.Io.Dir.cwd().openFile(io, root_zig, .{}) catch return false;
    defer file.close(io);
    return true;
}

pub const GenerateOptions = struct {
    /// The app name from app.zon (`metadata.name`); becomes the executable
    /// name and the generated package name.
    app_name: []const u8,
    /// Absolute path to the framework checkout (resolveFrameworkRoot).
    framework_root: []const u8,
};

/// Synthesize (or refresh) `<app>/.native/build/{build.zig,build.zig.zon}`.
/// Files are only rewritten when their content changed, so Zig's
/// content-hash cache stays warm across invocations. Returns the build-file
/// path relative to the app dir (for `zig build --build-file`).
pub fn ensureGeneratedBuild(allocator: std.mem.Allocator, io: std.Io, app_dir: []const u8, options: GenerateOptions) ![]const u8 {
    const gen_path = try std.fs.path.join(allocator, &.{ app_dir, generated_dir });
    defer allocator.free(gen_path);
    try std.Io.Dir.cwd().createDirPath(io, gen_path);

    // build.zig.zon path dependencies must be relative to the build root
    // (Zig rejects absolute paths), and both ends may contain symlinked
    // segments (/tmp -> /private/tmp), so compute against realpaths.
    const gen_real = try std.Io.Dir.cwd().realPathFileAlloc(io, gen_path, allocator);
    defer allocator.free(gen_real);
    const framework_real = try std.Io.Dir.realPathFileAbsoluteAlloc(io, options.framework_root, allocator);
    defer allocator.free(framework_real);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const dependency_path = try std.fs.path.relative(allocator, cwd, null, gen_real, framework_real);
    defer allocator.free(dependency_path);

    const zon_dependency_path: []const u8 = switch (routeDependencyPath(dependency_path)) {
        .relative => |path| path,
        .junction => bridge: {
            // Cross-volume (drive letters or UNC shares): wire the zon
            // through a `.native/sdk` junction instead of the absolute
            // path Zig rejects. Refreshed on every generation, so an SDK
            // that moved or was reinstalled elsewhere is retargeted here.
            const native_dir_real = std.fs.path.dirname(gen_real).?;
            const app_real = std.fs.path.dirname(native_dir_real) orelse native_dir_real;
            const junction_path = try std.fs.path.join(allocator, &.{ native_dir_real, "sdk" });
            defer allocator.free(junction_path);
            junction.ensure(allocator, io, junction_path, framework_real) catch |err| switch (err) {
                error.OutOfMemory, error.Canceled => |e| return e,
                else => {
                    std.debug.print(
                        \\cannot wire this app to the Native SDK: the app ({s})
                        \\and the SDK ({s})
                        \\sit on different Windows volumes, and build.zig.zon path
                        \\dependencies must be relative — no relative path crosses
                        \\volumes. The CLI bridges that with a directory junction at
                        \\{s}, but creating it failed ({t}).
                        \\
                    , .{ app_real, framework_real, sdk_junction_dir, err });
                    std.debug.print(cross_volume_ways_out, .{});
                    return error.CrossVolumeFramework;
                },
            };
            break :bridge junction_dependency_path;
        },
    };

    const build_zig = try renderBuildZig(allocator, options.app_name, .generated);
    defer allocator.free(build_zig);
    const build_zon = try renderBuildZon(allocator, options.app_name, zon_dependency_path, .generated);
    defer allocator.free(build_zon);

    var dir = try std.Io.Dir.cwd().openDir(io, gen_path, .{});
    defer dir.close(io);
    try writeIfChanged(allocator, io, dir, "build.zig", build_zig);
    try writeIfChanged(allocator, io, dir, "build.zig.zon", build_zon);

    return try std.fs.path.join(allocator, &.{ generated_dir, "build.zig" });
}

pub const EjectOptions = struct {
    app_name: []const u8,
    framework_root: []const u8,
};

/// Write an owned build.zig/build.zig.zon pair into the app directory.
/// Refuses when either file already exists — eject transfers ownership
/// exactly once and never overwrites a build the user may have edited.
pub fn eject(allocator: std.mem.Allocator, io: std.Io, app_dir: []const u8, options: EjectOptions) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, app_dir, .{});
    defer dir.close(io);
    if (fileExistsIn(io, dir, "build.zig") or fileExistsIn(io, dir, "build.zig.zon")) {
        return error.AlreadyEjected;
    }

    const app_real = try std.Io.Dir.cwd().realPathFileAlloc(io, app_dir, allocator);
    defer allocator.free(app_real);
    const framework_real = try std.Io.Dir.realPathFileAbsoluteAlloc(io, options.framework_root, allocator);
    defer allocator.free(framework_real);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const dependency_path = try std.fs.path.relative(allocator, cwd, null, app_real, framework_real);
    defer allocator.free(dependency_path);

    const zon_dependency_path: []const u8 = switch (routeDependencyPath(dependency_path)) {
        .relative => |path| path,
        // No junction bridge for eject: the ejected build belongs to the
        // user and is driven by plain `zig build`, so the CLI would never
        // refresh a `.native/sdk` junction again — it would silently rot
        // the first time the SDK moves. Teach the constraint instead.
        .junction => {
            std.debug.print(
                \\cannot eject: the app ({s})
                \\and the Native SDK ({s})
                \\sit on different Windows volumes, and the ejected
                \\build.zig.zon needs a relative SDK path — no relative path
                \\crosses volumes, and an ejected build is user-owned, so the
                \\CLI cannot keep a junction bridge fresh for it.
                \\
            , .{ app_real, framework_real });
            std.debug.print(cross_volume_ways_out, .{});
            return error.CrossVolumeFramework;
        },
    };

    const build_zig = try renderBuildZig(allocator, options.app_name, .ejected);
    defer allocator.free(build_zig);
    const build_zon = try renderBuildZon(allocator, options.app_name, zon_dependency_path, .ejected);
    defer allocator.free(build_zon);

    try dir.writeFile(io, .{ .sub_path = "build.zig", .data = build_zig });
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = build_zon });
}

const Shape = enum {
    /// Lives in .native/build/ and is regenerated; app sources sit two
    /// directories up.
    generated,
    /// Lives in the app directory and belongs to the user.
    ejected,
};

pub fn renderBuildZig(allocator: std.mem.Allocator, app_name: []const u8, shape: Shape) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    switch (shape) {
        .generated => try out.appendSlice(allocator,
            \\//! Generated by the `native` CLI — do not edit. This file is
            \\//! re-synthesized from app.zon on every `native dev|build|test`
            \\//! and any change here is overwritten. Run `native eject` to
            \\//! write a build.zig you own into the app directory instead.
            \\
            \\
        ),
        .ejected => try out.appendSlice(allocator,
            \\//! This build belongs to your app, written once by `native eject`:
            \\//! the `native` CLI stops generating a build graph and
            \\//! drives this file through `zig build` instead, and it will
            \\//! never rewrite it. `addApp` wires the complete standard app
            \\//! build — executable, `zig build run`, `zig build test`, and
            \\//! the -Dplatform/-Dweb-engine/-Dautomation/-Doptimize flags —
            \\//! from the framework's build/app.zig, so a framework upgrade
            \\//! still upgrades your build. Extend from here with
            \\//! `addAppArtifacts` when you need extra sources or steps.
            \\
            \\
        ),
    }
    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\const native_sdk = @import("native_sdk");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    native_sdk.addApp(b, b.dependency("native_sdk", .{}), .{ .name =
    );
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, app_name);
    switch (shape) {
        .generated => try out.appendSlice(allocator, ", .app_root = \"../..\""),
        .ejected => {},
    }
    try out.appendSlice(allocator,
        \\ });
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

pub fn renderBuildZon(allocator: std.mem.Allocator, app_name: []const u8, dependency_path: []const u8, shape: Shape) ![]u8 {
    const module_name = try templates.normalizeModuleName(allocator, app_name);
    defer allocator.free(module_name);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, ".{\n    .name = .");
    try out.appendSlice(allocator, module_name);
    try out.appendSlice(allocator, ",\n    .fingerprint = 0x");
    var fingerprint_buffer: [16]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&fingerprint_buffer, "{x}", .{templates.fingerprintForName(module_name)}));
    try out.appendSlice(allocator,
        \\,
        \\    .version = "0.1.0",
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{ .native_sdk = .{ .path =
    );
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, dependency_path);
    try out.appendSlice(allocator, " } },\n");
    switch (shape) {
        .generated => try out.appendSlice(allocator, "    .paths = .{ \"build.zig\", \"build.zig.zon\" },\n"),
        .ejected => try out.appendSlice(allocator, "    .paths = .{ \"build.zig\", \"build.zig.zon\", \"src\", \"assets\", \"app.zon\" },\n"),
    }
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

fn writeIfChanged(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    existing: {
        const current = dir.readFileAlloc(io, sub_path, allocator, .limited(1024 * 1024)) catch break :existing;
        defer allocator.free(current);
        if (std.mem.eql(u8, current, data)) return;
    }
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

pub fn fileExistsIn(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) bool {
    const stat = dir.statFile(io, sub_path, .{}) catch return false;
    return stat.kind == .file;
}

pub fn fileExists(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

test "generated build.zig points addApp two directories up" {
    const text = try renderBuildZig(std.testing.allocator, "my-app", .generated);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Generated by the `native` CLI") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".name = \"my-app\", .app_root = \"../..\"") != null);
}

test "ejected build.zig is the plain addApp call with an ownership header" {
    const text = try renderBuildZig(std.testing.allocator, "my-app", .ejected);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "native eject") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".{ .name = \"my-app\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "app_root") == null);
}

test "generated build.zig.zon wires the framework path dependency" {
    const text = try renderBuildZon(std.testing.allocator, "my-app", "../../../framework", .generated);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, ".name = .my_app") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".native_sdk = .{ .path = \"../../../framework\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".paths = .{ \"build.zig\", \"build.zig.zon\" }") != null);
}

test "dependency routing keeps relative paths and bridges cross-volume ones" {
    // Same volume (and every non-Windows host): verbatim, zero change.
    try std.testing.expectEqualStrings("../../../framework", routeDependencyPath("../../../framework").relative);
    try std.testing.expectEqualStrings("..\\..\\sdk", routeDependencyPath("..\\..\\sdk").relative);
    // Build root == framework root: relative() returns "", the zon gets ".".
    try std.testing.expectEqualStrings(".", routeDependencyPath("").relative);
    // Cross-volume: std.fs.path.relative degrades to the absolute target
    // (drive letters or UNC shares), which must route through the junction.
    try std.testing.expect(routeDependencyPath("C:\\Users\\alpha\\AppData\\Roaming\\npm\\node_modules\\@native-sdk\\cli") == .junction);
    try std.testing.expect(routeDependencyPath("\\\\server\\share\\native-sdk") == .junction);
}

test "the junction route renders a relative zon path through .native/sdk" {
    const text = try renderBuildZon(std.testing.allocator, "my-app", junction_dependency_path, .generated);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, ".native_sdk = .{ .path = \"../sdk\" }") != null);
    // Never an absolute path in the zon, junction route included.
    try std.testing.expect(std.mem.indexOf(u8, text, ".path = \"C:") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".path = \"\\\\") == null);
}

test "the cross-volume teaching text names both user-level ways out" {
    try std.testing.expect(std.mem.indexOf(u8, cross_volume_ways_out, "same volume") != null);
    try std.testing.expect(std.mem.indexOf(u8, cross_volume_ways_out, "npm config set prefix") != null);
}

/// Path equality where '/' in the expected value also matches the
/// platform separator, so tests written with forward slashes hold on
/// Windows (where std.fs.path.join emits backslashes).
fn expectPathEqualStrings(expected: []const u8, actual: []const u8) !void {
    const matches = expected.len == actual.len and for (expected, actual) |e, a| {
        if (e != a and !(e == '/' and a == std.fs.path.sep)) break false;
    } else true;
    if (!matches) try std.testing.expectEqualStrings(expected, actual);
}

test "ensureGeneratedBuild synthesizes and refreshes the cache graph" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = ".zig-cache/test-buildgraph-app";
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, root);

    const framework = try cwd.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(framework);

    const build_file = try ensureGeneratedBuild(allocator, io, root, .{ .app_name = "demo", .framework_root = framework });
    defer allocator.free(build_file);
    // The returned path is joined with the platform separator (backslash
    // on Windows), so compare separator-agnostically.
    try expectPathEqualStrings(generated_dir ++ "/build.zig", build_file);

    var dir = try cwd.openDir(io, root ++ "/" ++ generated_dir, .{});
    defer dir.close(io);
    const zig_text = try dir.readFileAlloc(io, "build.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(zig_text);
    try std.testing.expect(std.mem.indexOf(u8, zig_text, ".app_root = \"../..\"") != null);
    const zon_text = try dir.readFileAlloc(io, "build.zig.zon", allocator, .limited(1024 * 1024));
    defer allocator.free(zon_text);
    // The dependency path must be relative: Zig rejects absolute paths in
    // build.zig.zon path dependencies.
    try std.testing.expect(std.mem.indexOf(u8, zon_text, ".path = \"/") == null);
    try std.testing.expect(std.mem.indexOf(u8, zon_text, ".path = \"..") != null);

    // Regeneration with the same inputs is a no-op (content unchanged).
    const again = try ensureGeneratedBuild(allocator, io, root, .{ .app_name = "demo", .framework_root = framework });
    defer allocator.free(again);
}

test "eject refuses to overwrite an existing build.zig" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = ".zig-cache/test-buildgraph-eject";
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, root);
    try cwd.writeFile(io, .{ .sub_path = root ++ "/build.zig", .data = "// mine\n" });

    const framework = try cwd.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(framework);
    try std.testing.expectError(error.AlreadyEjected, eject(allocator, io, root, .{ .app_name = "demo", .framework_root = framework }));
}

test "eject writes an owned pair once" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = ".zig-cache/test-buildgraph-eject-ok";
    var cwd = std.Io.Dir.cwd();
    // Reset from previous runs: eject-once means the fixture must start clean.
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);

    const framework = try cwd.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(framework);
    try eject(allocator, io, root, .{ .app_name = "demo", .framework_root = framework });

    var dir = try cwd.openDir(io, root, .{});
    defer dir.close(io);
    const zig_text = try dir.readFileAlloc(io, "build.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(zig_text);
    try std.testing.expect(std.mem.indexOf(u8, zig_text, "addApp") != null);
    const zon_text = try dir.readFileAlloc(io, "build.zig.zon", allocator, .limited(1024 * 1024));
    defer allocator.free(zon_text);
    try std.testing.expect(std.mem.indexOf(u8, zon_text, ".native_sdk = .{ .path = ") != null);

    // Second eject refuses.
    try std.testing.expectError(error.AlreadyEjected, eject(allocator, io, root, .{ .app_name = "demo", .framework_root = framework }));
}

fn appendZigString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
}
