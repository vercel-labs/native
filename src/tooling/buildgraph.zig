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

pub const generated_dir = ".native/build";

pub const Error = error{
    MissingFramework,
    AlreadyEjected,
};

/// Where the `native_sdk` framework checkout lives, for wiring the path
/// dependency of a generated or ejected build graph. Resolution order:
///   1. NATIVE_SDK_PATH environment variable (explicit override)
///   2. derived from the CLI executable location (`<root>/zig-out/bin/native`
///      in a framework checkout, `<package>/bin/native` in the npm package)
/// Returns an absolute path, or null when neither resolves.
pub fn resolveFrameworkRoot(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !?[]const u8 {
    if (env_map.get("NATIVE_SDK_PATH")) |path| {
        if (path.len > 0 and hasFrameworkRoot(allocator, io, path)) {
            if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);
            return try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
        }
    }

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_len = std.process.executablePath(io, &buffer) catch return null;
    const executable_path = buffer[0..executable_len];
    const bin_dir = std.fs.path.dirname(executable_path) orelse return null;
    const package_root = std.fs.path.dirname(bin_dir) orelse return null;
    if (hasFrameworkRoot(allocator, io, package_root)) {
        return try allocator.dupe(u8, package_root);
    }
    if (std.fs.path.dirname(package_root)) |repo_root| {
        if (hasFrameworkRoot(allocator, io, repo_root)) {
            return try allocator.dupe(u8, repo_root);
        }
    }
    return null;
}

fn hasFrameworkRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8) bool {
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

    const build_zig = try renderBuildZig(allocator, options.app_name, .generated);
    defer allocator.free(build_zig);
    const build_zon = try renderBuildZon(allocator, options.app_name, if (dependency_path.len == 0) "." else dependency_path, .generated);
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

    const build_zig = try renderBuildZig(allocator, options.app_name, .ejected);
    defer allocator.free(build_zig);
    const build_zon = try renderBuildZon(allocator, options.app_name, if (dependency_path.len == 0) "." else dependency_path, .ejected);
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
    try std.testing.expectEqualStrings(generated_dir ++ "/build.zig", build_file);

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
