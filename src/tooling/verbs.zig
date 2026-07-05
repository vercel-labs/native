//! The canonical app verbs: `native dev|build|test` work in any app
//! directory. If the app owns a build.zig (ejected, and every example),
//! the verbs drive it through plain `zig build` — zero behavior change.
//! Otherwise (app.zon + src/ only) the CLI synthesizes the build graph
//! into `<app>/.native/build/` (see buildgraph.zig) and drives that.
//!
//! Callers are expected to have chdir'd into the app directory: every
//! relative path an app uses at runtime (assets/, the src/app.zml hot
//! reload watcher, .zig-cache/native-sdk-automation) resolves against the
//! process cwd, so the verbs run zig — and the app — from the app root.

const std = @import("std");
const buildgraph = @import("buildgraph.zig");
const toolchain = @import("toolchain.zig");
const manifest_tool = @import("manifest.zig");
const dev_tool = @import("dev.zig");

pub const Error = error{
    MissingManifest,
    MissingFramework,
};

pub const Verb = enum {
    dev,
    build,
    @"test",
};

pub const Options = struct {
    base_env: *std.process.Environ.Map,
    /// --yes: consent to toolchain download without a prompt.
    assume_yes: bool = false,
    /// -D.../--release flags forwarded verbatim to `zig build`.
    forwarded_args: []const []const u8 = &.{},
    /// dev-only: frontend dev server overrides (same as `native dev` flags).
    url_override: ?[]const u8 = null,
    command_override: ?[]const []const u8 = null,
    timeout_ms: ?u32 = null,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, verb: Verb, options: Options) !void {
    if (!buildgraph.fileExists(io, "app.zon")) {
        std.debug.print(
            \\no app.zon here — `native {s}` runs inside an app directory
            \\(or pass one: `native {s} path/to/app`). Start one with `native init`.
            \\
        , .{ @tagName(verb), @tagName(verb) });
        return error.MissingManifest;
    }
    const metadata = try manifest_tool.readMetadata(allocator, io, "app.zon");

    const zig_exe = try toolchain.resolveZig(allocator, io, options.base_env, .{ .assume_yes = options.assume_yes });
    defer allocator.free(zig_exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ zig_exe, "build" });

    const ejected = buildgraph.fileExists(io, "build.zig");
    var build_file: ?[]const u8 = null;
    defer if (build_file) |path| allocator.free(path);
    var prefix: ?[]const u8 = null;
    defer if (prefix) |path| allocator.free(path);
    if (!ejected) {
        const framework_root = try buildgraph.resolveFrameworkRoot(allocator, io, options.base_env) orelse {
            std.debug.print(
                \\cannot locate the Native SDK framework for this app.
                \\Set NATIVE_SDK_PATH to your framework checkout, or run a
                \\`native` binary that lives inside one (zig-out/bin/native).
                \\
            , .{});
            return error.MissingFramework;
        };
        defer allocator.free(framework_root);
        build_file = try buildgraph.ensureGeneratedBuild(allocator, io, ".", .{
            .app_name = metadata.name,
            .framework_root = framework_root,
        });
        // Keep artifacts where users expect them: the generated build root
        // is .native/build/, so without a prefix the binary would hide in
        // .native/build/zig-out/. Absolute path: a relative --prefix would
        // resolve against the build root, not the app dir.
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        prefix = try std.fs.path.join(allocator, &.{ cwd, "zig-out" });
        try argv.appendSlice(allocator, &.{ "--build-file", build_file.?, "--prefix", prefix.? });
    }

    const wants_frontend_dev = verb == .dev and metadata.frontend != null and metadata.frontend.?.dev != null;
    var release_fast = false;
    switch (verb) {
        .dev => if (!wants_frontend_dev) try argv.append(allocator, "run"),
        .build => {
            if (!hasOptimizeFlag(options.forwarded_args)) {
                // Both build shapes register -Doptimize (addApp and the
                // expanded template's standardOptimizeOption).
                try argv.append(allocator, "-Doptimize=ReleaseFast");
                release_fast = true;
            }
        },
        .@"test" => try argv.append(allocator, "test"),
    }
    try argv.appendSlice(allocator, options.forwarded_args);

    try runZig(io, argv.items);

    if (wants_frontend_dev) {
        // WebView apps with a dev server config: the binary is built, now
        // hand off to the frontend dev flow (server + shell + HMR env).
        const binary_path = try std.fs.path.join(allocator, &.{ "zig-out", "bin", metadata.name });
        defer allocator.free(binary_path);
        try dev_tool.run(allocator, io, .{
            .metadata = metadata,
            .base_env = options.base_env,
            .binary_path = binary_path,
            .url_override = options.url_override,
            .command_override = options.command_override,
            .timeout_ms = options.timeout_ms,
        });
    } else if (verb == .build) {
        std.debug.print("built zig-out/bin/{s}{s}\n", .{ metadata.name, if (release_fast) " (ReleaseFast)" else "" });
    }
}

fn hasOptimizeFlag(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-Doptimize")) return true;
        if (std.mem.startsWith(u8, arg, "--release")) return true;
    }
    return false;
}

fn runZig(io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.ZigBuildFailed;
}

test "optimize flags are detected among forwarded args" {
    try std.testing.expect(hasOptimizeFlag(&.{"-Doptimize=Debug"}));
    try std.testing.expect(hasOptimizeFlag(&.{ "-Dautomation=true", "--release=safe" }));
    try std.testing.expect(!hasOptimizeFlag(&.{"-Dautomation=true"}));
    try std.testing.expect(!hasOptimizeFlag(&.{}));
}
