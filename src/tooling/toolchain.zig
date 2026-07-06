//! Zero-config Zig toolchain: the CLI's own version pins the framework +
//! Zig pair, so `native dev|build|test` can bootstrap a machine that has
//! no (or the wrong) Zig. Resolution order:
//!   1. NATIVE_SDK_ZIG environment variable (explicit override, trusted)
//!   2. `zig` on PATH when its version is compatible with the pin (same
//!      major.minor, at least the pinned patch)
//!   3. a managed toolchain at ~/.native/toolchains/zig-<version>/
//!   4. offer to download the official build from ziglang.org into (3) —
//!      explicit consent in interactive mode, --yes for automation, and
//!      the archive is checksum-verified against SHA-256 sums pinned in
//!      this file (recorded from ziglang.org/download at pin time, so a
//!      compromised download host cannot swap the archive undetected).
//!
//! ~/.native is the CLI's convention for durable machine state (vs the
//! per-app, disposable `<app>/.native/`).

const std = @import("std");
const builtin = @import("builtin");

pub const pinned_zig_version = "0.16.0";

pub const Error = error{
    ZigUnavailable,
    DownloadDeclined,
    UnsupportedPlatform,
    ChecksumMismatch,
    CommandFailed,
};

const Download = struct {
    /// Archive basename under https://ziglang.org/download/<version>/.
    archive: []const u8,
    /// SHA-256 of the archive, from the official release index at pin time.
    sha256: []const u8,
    /// Directory name inside the archive (the archive basename without
    /// its .tar.xz extension).
    extracted_root: []const u8,
};

/// Official Zig 0.16.0 release archives (ziglang.org/download/index.json).
/// Update together with pinned_zig_version.
fn currentDownload() ?Download {
    return switch (builtin.target.os.tag) {
        .macos => switch (builtin.target.cpu.arch) {
            .aarch64 => .{
                .archive = "zig-aarch64-macos-0.16.0.tar.xz",
                .sha256 = "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489",
                .extracted_root = "zig-aarch64-macos-0.16.0",
            },
            .x86_64 => .{
                .archive = "zig-x86_64-macos-0.16.0.tar.xz",
                .sha256 = "0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7",
                .extracted_root = "zig-x86_64-macos-0.16.0",
            },
            else => null,
        },
        .linux => switch (builtin.target.cpu.arch) {
            .aarch64 => .{
                .archive = "zig-aarch64-linux-0.16.0.tar.xz",
                .sha256 = "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17",
                .extracted_root = "zig-aarch64-linux-0.16.0",
            },
            .x86_64 => .{
                .archive = "zig-x86_64-linux-0.16.0.tar.xz",
                .sha256 = "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00",
                .extracted_root = "zig-x86_64-linux-0.16.0",
            },
            else => null,
        },
        else => null,
    };
}

pub const Source = enum {
    env,
    path,
    managed,
};

pub const Resolution = struct {
    /// argv[0] for invoking zig; owned by the caller's allocator.
    zig: []const u8,
    source: Source,
};

pub const ResolveOptions = struct {
    /// Skip the consent prompt and download immediately (--yes).
    assume_yes: bool = false,
};

/// Find a usable Zig, downloading the pinned toolchain with consent when
/// none exists. Errors are teaching: every failure path prints what to do.
pub fn resolveZig(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, options: ResolveOptions) ![]const u8 {
    return (try resolve(allocator, io, env_map, options)).zig;
}

pub fn resolve(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, options: ResolveOptions) !Resolution {
    if (env_map.get("NATIVE_SDK_ZIG")) |override| {
        if (override.len > 0) {
            return .{ .zig = try allocator.dupe(u8, override), .source = .env };
        }
    }

    if (pathZigVersion(allocator, io)) |version| {
        defer allocator.free(version);
        if (versionCompatible(version, pinned_zig_version)) {
            return .{ .zig = try allocator.dupe(u8, "zig"), .source = .path };
        }
        std.debug.print("found zig {s} on PATH, but this Native SDK is pinned to zig {s}\n", .{ version, pinned_zig_version });
    }

    const managed = try managedZigPath(allocator, env_map);
    errdefer allocator.free(managed);
    if (fileExists(io, managed)) {
        return .{ .zig = managed, .source = .managed };
    }

    try offerInstall(allocator, io, env_map, options);
    if (!fileExists(io, managed)) return error.ZigUnavailable;
    return .{ .zig = managed, .source = .managed };
}

/// ~/.native/toolchains/zig-<version>/zig
pub fn managedZigPath(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) ![]const u8 {
    const root = try toolchainRoot(allocator, env_map);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "zig-" ++ pinned_zig_version, "zig" });
}

fn toolchainRoot(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) ![]const u8 {
    if (env_map.get("NATIVE_SDK_HOME")) |home| {
        if (home.len > 0) return std.fs.path.join(allocator, &.{ home, "toolchains" });
    }
    if (builtin.target.os.tag == .windows) {
        if (env_map.get("USERPROFILE")) |home| {
            if (home.len > 0) return std.fs.path.join(allocator, &.{ home, ".native", "toolchains" });
        }
    }
    if (env_map.get("HOME")) |home| {
        if (home.len > 0) return std.fs.path.join(allocator, &.{ home, ".native", "toolchains" });
    }
    return error.ZigUnavailable;
}

fn pathZigVersion(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "version" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return null;
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (trimmed.len == 0) {
        allocator.free(result.stdout);
        return null;
    }
    const version = allocator.dupe(u8, trimmed) catch {
        allocator.free(result.stdout);
        return null;
    };
    allocator.free(result.stdout);
    return version;
}

/// A PATH zig satisfies the pin when major.minor match and the patch is at
/// least the pinned one. Dev builds ("0.17.0-dev.123+abc") never match a
/// release pin: their behavior drifts from the pinned framework pair.
pub fn versionCompatible(actual: []const u8, pinned: []const u8) bool {
    const actual_version = std.SemanticVersion.parse(actual) catch return false;
    const pinned_version = std.SemanticVersion.parse(pinned) catch return false;
    if (actual_version.pre != null) return false;
    return actual_version.major == pinned_version.major and
        actual_version.minor == pinned_version.minor and
        actual_version.patch >= pinned_version.patch;
}

fn offerInstall(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, options: ResolveOptions) !void {
    const download = currentDownload() orelse {
        std.debug.print(
            \\zig {s} is required but was not found, and this platform has no
            \\managed toolchain download. Install it from the official Zig
            \\download page, then re-run.
            \\
        , .{pinned_zig_version});
        return error.UnsupportedPlatform;
    };

    if (!options.assume_yes) {
        const interactive = std.Io.File.stdin().isTty(io) catch false;
        if (!interactive) {
            std.debug.print(
                \\zig {s} is required but was not found on PATH.
                \\Re-run with --yes to let `native` download the official build
                \\into ~/.native/toolchains/zig-{s}/, or install Zig yourself.
                \\
            , .{ pinned_zig_version, pinned_zig_version });
            return error.DownloadDeclined;
        }
        std.debug.print(
            \\zig {s} is required but was not found on PATH.
            \\Download the official build from ziglang.org (~55 MB, checksum
            \\verified) into ~/.native/toolchains/zig-{s}/? [Y/n]
        , .{ pinned_zig_version, pinned_zig_version });
        if (!readYes(io)) {
            std.debug.print("declined; install zig {s} and re-run\n", .{pinned_zig_version});
            return error.DownloadDeclined;
        }
    }

    try install(allocator, io, env_map, download);
}

fn readYes(io: std.Io) bool {
    var buffer: [64]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buffer);
    const line = reader.interface.takeDelimiterExclusive('\n') catch return false;
    const answer = std.mem.trim(u8, line, " \r\t");
    if (answer.len == 0) return true;
    return answer[0] == 'y' or answer[0] == 'Y';
}

fn install(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, download: Download) !void {
    const root = try toolchainRoot(allocator, env_map);
    defer allocator.free(root);
    const downloads_dir = try std.fs.path.join(allocator, &.{ root, ".downloads" });
    defer allocator.free(downloads_dir);
    try std.Io.Dir.cwd().createDirPath(io, downloads_dir);

    const archive_path = try std.fs.path.join(allocator, &.{ downloads_dir, download.archive });
    defer allocator.free(archive_path);
    const url = try std.fmt.allocPrint(allocator, "https://ziglang.org/download/{s}/{s}", .{ pinned_zig_version, download.archive });
    defer allocator.free(url);

    std.debug.print("downloading {s}\n", .{url});
    try runCommand(io, &.{ "curl", "--fail", "--location", "--output", archive_path, url });
    try verifyChecksum(allocator, io, downloads_dir, download.archive, download.sha256);

    const extract_dir = try std.fs.path.join(allocator, &.{ downloads_dir, "extract-tmp" });
    defer allocator.free(extract_dir);
    runCommand(io, &.{ "rm", "-rf", extract_dir }) catch {};
    try std.Io.Dir.cwd().createDirPath(io, extract_dir);
    try runCommand(io, &.{ "tar", "-xJf", archive_path, "-C", extract_dir });

    const extracted = try std.fs.path.join(allocator, &.{ extract_dir, download.extracted_root });
    defer allocator.free(extracted);
    const final_dir = try std.fs.path.join(allocator, &.{ root, "zig-" ++ pinned_zig_version });
    defer allocator.free(final_dir);
    runCommand(io, &.{ "rm", "-rf", final_dir }) catch {};
    try runCommand(io, &.{ "mv", extracted, final_dir });
    runCommand(io, &.{ "rm", "-rf", extract_dir }) catch {};
    runCommand(io, &.{ "rm", "-f", archive_path }) catch {};

    const zig_exe = try std.fs.path.join(allocator, &.{ final_dir, "zig" });
    defer allocator.free(zig_exe);
    const result = std.process.run(allocator, io, .{
        .argv = &.{ zig_exe, "version" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(4096),
    }) catch return error.CommandFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.CommandFailed;
    std.debug.print("installed zig {s} at {s}\n", .{ std.mem.trim(u8, result.stdout, " \r\n\t"), final_dir });
}

const sha256_shell_snippet = if (builtin.target.os.tag == .windows)
    "sha256sum"
else
    "shasum -a 256";

fn verifyChecksum(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, archive_name: []const u8, expected: []const u8) !void {
    const quoted_dir = try shellQuote(allocator, dir);
    defer allocator.free(quoted_dir);
    const quoted_archive = try shellQuote(allocator, archive_name);
    defer allocator.free(quoted_archive);
    const command = try std.fmt.allocPrint(
        allocator,
        "cd {s} && actual=$(" ++ sha256_shell_snippet ++ " {s} | awk '{{print $1}}') && if [ \"$actual\" != \"{s}\" ]; then echo \"zig archive checksum mismatch: expected {s}, got $actual\" >&2; exit 1; fi",
        .{ quoted_dir, quoted_archive, expected, expected },
    );
    defer allocator.free(command);
    runCommand(io, &.{ "sh", "-c", command }) catch return error.ChecksumMismatch;
}

fn runCommand(io: std.Io, argv: []const []const u8) !void {
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
    return error.CommandFailed;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

test "version compatibility pins major.minor and floors the patch" {
    try std.testing.expect(versionCompatible("0.16.0", "0.16.0"));
    try std.testing.expect(versionCompatible("0.16.2", "0.16.0"));
    try std.testing.expect(!versionCompatible("0.15.1", "0.16.0"));
    try std.testing.expect(!versionCompatible("0.17.0", "0.16.0"));
    try std.testing.expect(!versionCompatible("1.16.0", "0.16.0"));
    try std.testing.expect(!versionCompatible("0.17.0-dev.123+abcdef", "0.16.0"));
    try std.testing.expect(!versionCompatible("garbage", "0.16.0"));
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

test "managed toolchain lives under ~/.native/toolchains" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/Users/alice");
    const path = try managedZigPath(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);
    try expectPathEqualStrings("/Users/alice/.native/toolchains/zig-" ++ pinned_zig_version ++ "/zig", path);
}

test "NATIVE_SDK_HOME overrides the toolchain root" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/Users/alice");
    try env.put("NATIVE_SDK_HOME", "/durable/native");
    const path = try managedZigPath(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);
    try expectPathEqualStrings("/durable/native/toolchains/zig-" ++ pinned_zig_version ++ "/zig", path);
}

test "NATIVE_SDK_ZIG overrides resolution" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("NATIVE_SDK_ZIG", "/opt/zig/zig");
    const resolution = try resolve(std.testing.allocator, std.testing.io, &env, .{});
    defer std.testing.allocator.free(resolution.zig);
    try std.testing.expectEqualStrings("/opt/zig/zig", resolution.zig);
    try std.testing.expectEqual(Source.env, resolution.source);
}
