const std = @import("std");
const builtin = @import("builtin");

pub const default_version = "144.0.6+g5f7e671+chromium-144.0.7559.59";
pub const default_prepared_download_url = "https://github.com/vercel-labs/native/releases/download";
pub const default_official_download_url = "https://cef-builds.spotifycdn.com";
pub const default_download_url = default_prepared_download_url;
pub const default_macos_dir = "third_party/cef/macos";
pub const default_linux_dir = "third_party/cef/linux";
pub const default_windows_dir = "third_party/cef/windows";
pub const default_dir = "";
pub const default_release_output_dir = "zig-out/cef";

const sha256_shell_snippet = if (builtin.target.os.tag == .windows)
    "sha256sum"
else
    "shasum -a 256";

pub const Error = error{
    InvalidArguments,
    UnsupportedPlatform,
    MissingLayout,
    CommandFailed,
    WrapperBuildFailed,
};

pub const EntryKind = enum {
    file,
    directory,
};

pub const RequiredEntry = struct {
    path: []const u8,
    kind: EntryKind,
};

pub const macos_required_entries = [_]RequiredEntry{
    .{ .path = "include/cef_app.h", .kind = .file },
    .{ .path = "Release/Chromium Embedded Framework.framework", .kind = .directory },
    .{ .path = "libcef_dll_wrapper/libcef_dll_wrapper.a", .kind = .file },
};

pub const linux_required_entries = [_]RequiredEntry{
    .{ .path = "include/cef_app.h", .kind = .file },
    .{ .path = "Release/libcef.so", .kind = .file },
    .{ .path = "libcef_dll_wrapper/libcef_dll_wrapper.a", .kind = .file },
};

pub const windows_required_entries = [_]RequiredEntry{
    .{ .path = "include/cef_app.h", .kind = .file },
    .{ .path = "Release/libcef.dll", .kind = .file },
    .{ .path = "libcef_dll_wrapper/libcef_dll_wrapper.lib", .kind = .file },
};

pub const LayoutReport = struct {
    ok: bool,
    missing_path: ?[]const u8 = null,
};

pub const Platform = enum {
    macosx64,
    macosarm64,
    linux64,
    linuxarm64,
    windows64,
    windowsarm64,

    pub fn current() Error!Platform {
        return switch (builtin.target.os.tag) {
            .macos => switch (builtin.target.cpu.arch) {
                .x86_64 => .macosx64,
                .aarch64 => .macosarm64,
                else => error.UnsupportedPlatform,
            },
            .linux => switch (builtin.target.cpu.arch) {
                .x86_64 => .linux64,
                .aarch64 => .linuxarm64,
                else => error.UnsupportedPlatform,
            },
            .windows => switch (builtin.target.cpu.arch) {
                .x86_64 => .windows64,
                .aarch64 => .windowsarm64,
                else => error.UnsupportedPlatform,
            },
            else => error.UnsupportedPlatform,
        };
    }

    pub fn name(self: Platform) []const u8 {
        return @tagName(self);
    }

    pub fn defaultDir(self: Platform) []const u8 {
        return switch (self) {
            .macosx64, .macosarm64 => default_macos_dir,
            .linux64, .linuxarm64 => default_linux_dir,
            .windows64, .windowsarm64 => default_windows_dir,
        };
    }

    pub fn requiredEntries(self: Platform) []const RequiredEntry {
        return switch (self) {
            .macosx64, .macosarm64 => &macos_required_entries,
            .linux64, .linuxarm64 => &linux_required_entries,
            .windows64, .windowsarm64 => &windows_required_entries,
        };
    }

    pub fn wrapperLibraryName(self: Platform) []const u8 {
        return switch (self) {
            .windows64, .windowsarm64 => "libcef_dll_wrapper.lib",
            else => "libcef_dll_wrapper.a",
        };
    }
};

pub const Source = enum {
    prepared,
    official,

    pub fn parse(value: []const u8) ?Source {
        if (std.mem.eql(u8, value, "prepared")) return .prepared;
        if (std.mem.eql(u8, value, "official")) return .official;
        return null;
    }
};

pub const InstallOptions = struct {
    dir: []const u8 = default_dir,
    version: []const u8 = default_version,
    source: Source = .prepared,
    download_url: ?[]const u8 = null,
    force: bool = false,
    allow_build_tools: bool = false,
};

pub const PrepareOptions = struct {
    dir: []const u8 = default_dir,
    output_dir: []const u8 = default_release_output_dir,
    version: []const u8 = default_version,
};

pub const InstallResult = struct {
    dir: []const u8,
    platform: Platform,
    installed: bool,
};

pub fn parseOptions(args: []const []const u8) Error!InstallOptions {
    var options: InstallOptions = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--dir")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.dir = args[index];
        } else if (std.mem.eql(u8, arg, "--version")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.version = args[index];
        } else if (std.mem.eql(u8, arg, "--source")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.source = Source.parse(args[index]) orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--download-url")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.download_url = args[index];
        } else if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--allow-build-tools")) {
            options.allow_build_tools = true;
        } else {
            return error.InvalidArguments;
        }
    }
    return options;
}

pub fn parsePrepareOptions(args: []const []const u8) Error!PrepareOptions {
    var options: PrepareOptions = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--dir")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.dir = args[index];
        } else if (std.mem.eql(u8, arg, "--output")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.output_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--version")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.version = args[index];
        } else {
            return error.InvalidArguments;
        }
    }
    return options;
}

pub fn preparedArchiveName(buffer: []u8, version: []const u8, platform: Platform) ![]const u8 {
    return std.fmt.bufPrint(buffer, "native-sdk-cef-{s}-{s}.tar.gz", .{ version, platform.name() });
}

pub fn archiveName(buffer: []u8, version: []const u8, platform: Platform) ![]const u8 {
    return std.fmt.bufPrint(buffer, "cef_binary_{s}_{s}.tar.bz2", .{ version, platform.name() });
}

fn trimTrailingSlashes(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') end -= 1;
    return value[0..end];
}

pub fn preparedArchiveUrl(allocator: std.mem.Allocator, base_url: []const u8, version: []const u8, platform: Platform) ![]const u8 {
    var name_buffer: [256]u8 = undefined;
    const name = try preparedArchiveName(&name_buffer, version, platform);
    return std.fmt.allocPrint(allocator, "{s}/cef-{s}/{s}", .{ trimTrailingSlashes(base_url), version, name });
}

pub fn archiveUrl(allocator: std.mem.Allocator, base_url: []const u8, version: []const u8, platform: Platform) ![]const u8 {
    var name_buffer: [256]u8 = undefined;
    const name = try archiveName(&name_buffer, version, platform);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimTrailingSlashes(base_url), name });
}

pub fn cacheDir(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) ![]const u8 {
    if (env_map.get("XDG_CACHE_HOME")) |root| return std.fs.path.join(allocator, &.{ root, "native", "cef" });
    if (builtin.target.os.tag == .windows) {
        if (env_map.get("LOCALAPPDATA")) |root| return std.fs.path.join(allocator, &.{ root, "native", "cef" });
        if (env_map.get("USERPROFILE")) |home| return std.fs.path.join(allocator, &.{ home, "AppData", "Local", "native", "cef" });
    }
    if (env_map.get("HOME")) |home| {
        if (builtin.target.os.tag == .macos) return std.fs.path.join(allocator, &.{ home, "Library", "Caches", "native", "cef" });
        return std.fs.path.join(allocator, &.{ home, ".cache", "native", "cef" });
    }
    return allocator.dupe(u8, ".zig-cache/native-sdk-cef");
}

pub fn verifyLayout(io: std.Io, dir: []const u8) LayoutReport {
    const platform = Platform.current() catch .macosarm64;
    return verifyLayoutFor(io, platform, dir);
}

pub fn verifyLayoutFor(io: std.Io, platform: Platform, dir: []const u8) LayoutReport {
    for (platform.requiredEntries()) |entry| {
        var path_buffer: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&path_buffer);
        const path = std.fs.path.join(fba.allocator(), &.{ dir, entry.path }) catch return .{ .ok = false, .missing_path = entry.path };
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{ .ok = false, .missing_path = entry.path };
        switch (entry.kind) {
            .file => if (stat.kind != .file) return .{ .ok = false, .missing_path = entry.path },
            .directory => if (stat.kind != .directory) return .{ .ok = false, .missing_path = entry.path },
        }
    }
    return .{ .ok = true };
}

pub fn ensureLayout(io: std.Io, dir: []const u8) Error!void {
    const report = verifyLayout(io, dir);
    if (!report.ok) return error.MissingLayout;
}

pub fn ensureLayoutFor(io: std.Io, platform: Platform, dir: []const u8) Error!void {
    const report = verifyLayoutFor(io, platform, dir);
    if (!report.ok) return error.MissingLayout;
}

pub fn missingMessage(buffer: []u8, dir: []const u8, report: LayoutReport) []const u8 {
    if (report.ok) return std.fmt.bufPrint(buffer, "CEF layout is ready at {s}", .{dir}) catch "CEF layout is ready";
    return std.fmt.bufPrint(buffer, "CEF layout is missing {s} under {s}", .{ report.missing_path orelse "required files", dir }) catch "CEF layout is missing required files";
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, args: []const []const u8) !void {
    if (args.len == 0) return usage();
    const command = args[0];
    if (std.mem.eql(u8, command, "install")) {
        const options = try parseOptions(args[1..]);
        const result = try install(allocator, io, env_map, options);
        if (result.installed) {
            std.debug.print("CEF installed at {s}\n", .{result.dir});
        } else {
            std.debug.print("CEF already installed at {s}\n", .{result.dir});
        }
    } else if (std.mem.eql(u8, command, "path")) {
        const options = try parseOptions(args[1..]);
        const platform = try Platform.current();
        std.debug.print("{s}\n", .{resolveDir(options.dir, platform)});
    } else if (std.mem.eql(u8, command, "doctor")) {
        const options = try parseOptions(args[1..]);
        const platform = try Platform.current();
        const dir = resolveDir(options.dir, platform);
        const report = verifyLayoutFor(io, platform, dir);
        var message_buffer: [512]u8 = undefined;
        std.debug.print("{s}\n", .{missingMessage(&message_buffer, dir, report)});
        if (!report.ok) return error.MissingLayout;
    } else if (std.mem.eql(u8, command, "prepare-release")) {
        const options = try parsePrepareOptions(args[1..]);
        const artifact_path = try prepareRelease(allocator, io, options);
        defer allocator.free(artifact_path);
        std.debug.print("prepared CEF runtime at {s}\n", .{artifact_path});
    } else {
        return usage();
    }
}

pub fn install(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, options: InstallOptions) !InstallResult {
    const platform = try Platform.current();
    var resolved_options = options;
    resolved_options.dir = resolveDir(options.dir, platform);
    const existing = verifyLayoutFor(io, platform, resolved_options.dir);
    if (existing.ok and !options.force) {
        return .{ .dir = resolved_options.dir, .platform = platform, .installed = false };
    }

    return switch (options.source) {
        .prepared => installPrepared(allocator, io, env_map, resolved_options, platform, existing),
        .official => installOfficial(allocator, io, env_map, resolved_options, platform, existing),
    };
}

fn resolveDir(dir: []const u8, platform: Platform) []const u8 {
    return if (dir.len == 0) platform.defaultDir() else dir;
}

fn installPrepared(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, options: InstallOptions, platform: Platform, existing: LayoutReport) !InstallResult {
    const cache_path = try cacheDir(allocator, env_map);
    defer allocator.free(cache_path);
    try std.Io.Dir.cwd().createDirPath(io, cache_path);

    var archive_name_buffer: [256]u8 = undefined;
    const archive_name = try preparedArchiveName(&archive_name_buffer, options.version, platform);
    const archive_path = try std.fs.path.join(allocator, &.{ cache_path, archive_name });
    defer allocator.free(archive_path);
    const sha_path = try std.fmt.allocPrint(allocator, "{s}.sha256", .{archive_path});
    defer allocator.free(sha_path);

    const url = try preparedArchiveUrl(allocator, options.download_url orelse default_prepared_download_url, options.version, platform);
    defer allocator.free(url);
    const sha_url = try std.fmt.allocPrint(allocator, "{s}.sha256", .{url});
    defer allocator.free(sha_url);

    if (options.force or !pathExists(io, archive_path)) {
        downloadFile(io, archive_path, url) catch |err| {
            std.debug.print("Prepared native-sdk CEF runtime is not available at {s}\n", .{url});
            std.debug.print("Maintainers can publish it with the CEF runtime release workflow. Advanced users may run `native cef install --source official --allow-build-tools`.\n", .{});
            return err;
        };
    }
    if (options.force or !pathExists(io, sha_path)) {
        try downloadFile(io, sha_path, sha_url);
    }
    try verifyArchiveChecksum(allocator, io, cache_path, archive_name);

    const tmp_dir = try std.fs.path.join(allocator, &.{ cache_path, "extract-tmp" });
    defer allocator.free(tmp_dir);
    runCommand(io, &.{ "rm", "-rf", tmp_dir }) catch {};
    const layout_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "layout" });
    defer allocator.free(layout_dir);
    try std.Io.Dir.cwd().createDirPath(io, layout_dir);
    try runCommand(io, &.{ "tar", "-xzf", archive_path, "-C", layout_dir });

    try ensureLayoutFor(io, platform, layout_dir);

    if (pathExists(io, options.dir)) {
        if (!options.force and !existing.ok) {
            std.debug.print("replacing incomplete CEF directory at {s}\n", .{options.dir});
        }
        try runCommand(io, &.{ "rm", "-rf", options.dir });
    }
    if (std.fs.path.dirname(options.dir)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    try runCommand(io, &.{ "mv", layout_dir, options.dir });
    try ensureLayoutFor(io, platform, options.dir);

    return .{ .dir = options.dir, .platform = platform, .installed = true };
}

fn installOfficial(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, options: InstallOptions, platform: Platform, existing: LayoutReport) !InstallResult {
    if (!options.allow_build_tools) {
        std.debug.print("Official CEF archives require building libcef_dll_wrapper.a locally. Use the prepared runtime with `native cef install`, or opt in with `--source official --allow-build-tools`.\n", .{});
        return error.WrapperBuildFailed;
    }

    const cache_path = try cacheDir(allocator, env_map);
    defer allocator.free(cache_path);
    try std.Io.Dir.cwd().createDirPath(io, cache_path);

    var archive_name_buffer: [256]u8 = undefined;
    const archive_name = try archiveName(&archive_name_buffer, options.version, platform);
    const archive_path = try std.fs.path.join(allocator, &.{ cache_path, archive_name });
    defer allocator.free(archive_path);
    const sha_path = try std.fmt.allocPrint(allocator, "{s}.sha256", .{archive_path});
    defer allocator.free(sha_path);

    const url = try archiveUrl(allocator, options.download_url orelse default_official_download_url, options.version, platform);
    defer allocator.free(url);
    const sha_url = try std.fmt.allocPrint(allocator, "{s}.sha256", .{url});
    defer allocator.free(sha_url);

    if (options.force or !pathExists(io, archive_path)) try downloadFile(io, archive_path, url);
    if (options.force or !pathExists(io, sha_path)) try downloadFile(io, sha_path, sha_url);
    try verifyArchiveChecksum(allocator, io, cache_path, archive_name);

    const tmp_dir = try std.fs.path.join(allocator, &.{ cache_path, "extract-tmp" });
    defer allocator.free(tmp_dir);
    runCommand(io, &.{ "rm", "-rf", tmp_dir }) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);
    try runCommand(io, &.{ "tar", "-xjf", archive_path, "-C", tmp_dir });

    const extracted_root = try std.fs.path.join(allocator, &.{ tmp_dir, archive_name[0 .. archive_name.len - ".tar.bz2".len] });
    defer allocator.free(extracted_root);
    if (!pathExists(io, extracted_root)) return error.CommandFailed;

    if (pathExists(io, options.dir)) {
        if (!options.force and !existing.ok) {
            std.debug.print("replacing incomplete CEF directory at {s}\n", .{options.dir});
        }
        try runCommand(io, &.{ "rm", "-rf", options.dir });
    }
    if (std.fs.path.dirname(options.dir)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    try runCommand(io, &.{ "mv", extracted_root, options.dir });
    try ensureWrapperArchive(allocator, io, platform, options.dir);
    try ensureLayoutFor(io, platform, options.dir);

    return .{ .dir = options.dir, .platform = platform, .installed = true };
}

fn verifyArchiveChecksum(allocator: std.mem.Allocator, io: std.Io, cache_path: []const u8, archive_name: []const u8) !void {
    const quoted_cache = try shellQuote(allocator, cache_path);
    defer allocator.free(quoted_cache);
    const quoted_archive = try shellQuote(allocator, archive_name);
    defer allocator.free(quoted_archive);
    const command = try std.fmt.allocPrint(
        allocator,
        "cd {s} && expected=$(tr -d '[:space:]' < {s}.sha256) && actual=$(" ++ sha256_shell_snippet ++ " {s} | awk '{{print $1}}') && if [ \"$expected\" != \"$actual\" ]; then echo \"CEF archive checksum mismatch\" >&2; exit 1; fi",
        .{ quoted_cache, quoted_archive, quoted_archive },
    );
    defer allocator.free(command);
    try runCommand(io, &.{ "sh", "-c", command });
}

pub fn prepareRelease(allocator: std.mem.Allocator, io: std.Io, options: PrepareOptions) ![]const u8 {
    const platform = try Platform.current();
    const dir = resolveDir(options.dir, platform);
    try ensureLayoutFor(io, platform, dir);
    try std.Io.Dir.cwd().createDirPath(io, options.output_dir);

    var archive_name_buffer: [256]u8 = undefined;
    const name = try preparedArchiveName(&archive_name_buffer, options.version, platform);
    const archive_path = try std.fs.path.join(allocator, &.{ options.output_dir, name });
    errdefer allocator.free(archive_path);

    const quoted_dir = try shellQuote(allocator, dir);
    defer allocator.free(quoted_dir);
    const quoted_output = try shellQuote(allocator, options.output_dir);
    defer allocator.free(quoted_output);
    const quoted_name = try shellQuote(allocator, name);
    defer allocator.free(quoted_name);
    const force_local = if (builtin.target.os.tag == .windows) " --force-local" else "";
    const command = try std.fmt.allocPrint(
        allocator,
        "output_dir=$(cd {s} && pwd) && cd {s} && tar -czf" ++ force_local ++ " \"$output_dir\"/{s} include Release libcef_dll_wrapper $(test -d Resources && echo Resources) $(test -d locales && echo locales)",
        .{ quoted_output, quoted_dir, quoted_name },
    );
    defer allocator.free(command);
    try runCommand(io, &.{ "sh", "-c", command });

    const sha_command = try std.fmt.allocPrint(
        allocator,
        "cd {s} && " ++ sha256_shell_snippet ++ " {s} | awk '{{print $1}}' > {s}.sha256",
        .{ quoted_output, quoted_name, quoted_name },
    );
    defer allocator.free(sha_command);
    try runCommand(io, &.{ "sh", "-c", sha_command });

    return archive_path;
}

fn ensureWrapperArchive(allocator: std.mem.Allocator, io: std.Io, platform: Platform, dir: []const u8) !void {
    const wrapper_name = platform.wrapperLibraryName();
    const wrapper_path = try std.fs.path.join(allocator, &.{ dir, "libcef_dll_wrapper", wrapper_name });
    defer allocator.free(wrapper_path);
    if (pathExists(io, wrapper_path)) return;

    if (!commandAvailable(io, "cmake")) {
        std.debug.print("Official CEF source needs CMake to build libcef_dll_wrapper.a. Install it with `brew install cmake` or use the default prepared runtime with `native cef install`.\n", .{});
        return error.WrapperBuildFailed;
    }

    const build_dir = try std.fs.path.join(allocator, &.{ dir, "build", "libcef_dll_wrapper" });
    defer allocator.free(build_dir);
    try std.Io.Dir.cwd().createDirPath(io, build_dir);
    try runCommand(io, &.{ "cmake", "-S", dir, "-B", build_dir });
    try runCommand(io, &.{ "cmake", "--build", build_dir, "--target", "libcef_dll_wrapper", "--config", "Release" });

    const built = try findFileNamed(allocator, io, build_dir, wrapper_name);
    defer allocator.free(built);
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), built, std.Io.Dir.cwd(), wrapper_path, io, .{ .make_path = true, .replace = true });
}

fn findFileNamed(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, name: []const u8) ![]const u8 {
    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, std.fs.path.basename(entry.path), name)) {
            return std.fs.path.join(allocator, &.{ root_path, entry.path });
        }
    }
    return error.FileNotFound;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn commandAvailable(io: std.Io, name: []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "command -v \"$0\" >/dev/null 2>&1", name },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
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

fn downloadFile(io: std.Io, output_path: []const u8, url: []const u8) !void {
    return runCommand(io, &.{ "curl", "--fail", "--location", "--output", output_path, url });
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

fn usage() Error!void {
    std.debug.print(
        \\usage: native cef <command>
        \\
        \\commands:
        \\  install [--dir path] [--version version] [--source prepared|official] [--download-url url] [--allow-build-tools] [--force]
        \\  path [--dir path]
        \\  doctor [--dir path]
        \\  prepare-release [--dir path] [--output path] [--version version]
        \\
    , .{});
    return error.InvalidArguments;
}

test "archive names follow the CEF build convention" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("native-sdk-cef-1.2.3+gabc+chromium-4.5.6-macosarm64.tar.gz", try preparedArchiveName(&buffer, "1.2.3+gabc+chromium-4.5.6", .macosarm64));
    try std.testing.expectEqualStrings("cef_binary_1.2.3+gabc+chromium-4.5.6_macosarm64.tar.bz2", try archiveName(&buffer, "1.2.3+gabc+chromium-4.5.6", .macosarm64));
    try std.testing.expectEqualStrings("cef_binary_1.2.3+gabc+chromium-4.5.6_macosx64.tar.bz2", try archiveName(&buffer, "1.2.3+gabc+chromium-4.5.6", .macosx64));
    try std.testing.expectEqualStrings("cef_binary_1.2.3+gabc+chromium-4.5.6_linux64.tar.bz2", try archiveName(&buffer, "1.2.3+gabc+chromium-4.5.6", .linux64));
    try std.testing.expectEqualStrings("cef_binary_1.2.3+gabc+chromium-4.5.6_windows64.tar.bz2", try archiveName(&buffer, "1.2.3+gabc+chromium-4.5.6", .windows64));
}

test "archive urls trim trailing slash" {
    const prepared_url = try preparedArchiveUrl(std.testing.allocator, "https://example.com/releases/", "1.2.3", .macosarm64);
    defer std.testing.allocator.free(prepared_url);
    try std.testing.expectEqualStrings("https://example.com/releases/cef-1.2.3/native-sdk-cef-1.2.3-macosarm64.tar.gz", prepared_url);

    const url = try archiveUrl(std.testing.allocator, "https://example.com/", "1.2.3", .macosx64);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://example.com/cef_binary_1.2.3_macosx64.tar.bz2", url);
}

test "parse install options" {
    const options = try parseOptions(&.{ "--dir", "vendor/cef", "--version", "1.2.3", "--source", "official", "--download-url", "https://example.com", "--allow-build-tools", "--force" });
    try std.testing.expectEqualStrings("vendor/cef", options.dir);
    try std.testing.expectEqualStrings("1.2.3", options.version);
    try std.testing.expectEqual(Source.official, options.source);
    try std.testing.expectEqualStrings("https://example.com", options.download_url.?);
    try std.testing.expect(options.allow_build_tools);
    try std.testing.expect(options.force);
}

test "parse prepare-release options" {
    const options = try parsePrepareOptions(&.{ "--dir", "vendor/cef", "--output", "zig-out/cef", "--version", "1.2.3" });
    try std.testing.expectEqualStrings("vendor/cef", options.dir);
    try std.testing.expectEqualStrings("zig-out/cef", options.output_dir);
    try std.testing.expectEqualStrings("1.2.3", options.version);
}

test "layout verifier reports first missing entry" {
    const report = verifyLayout(std.testing.io, ".zig-cache/does-not-exist-cef");
    try std.testing.expect(!report.ok);
    try std.testing.expectEqualStrings("include/cef_app.h", report.missing_path.?);
}

test "layout verifier accepts complete macOS fixture" {
    const root = ".zig-cache/test-cef-layout";
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, root ++ "/include");
    try cwd.createDirPath(std.testing.io, root ++ "/Release/Chromium Embedded Framework.framework");
    try cwd.createDirPath(std.testing.io, root ++ "/libcef_dll_wrapper");
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/include/cef_app.h", .data = "" });
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/libcef_dll_wrapper/libcef_dll_wrapper.a", .data = "" });

    const report = verifyLayoutFor(std.testing.io, .macosarm64, root);
    try std.testing.expect(report.ok);
}

test "layout verifier accepts complete linux fixture" {
    const root = ".zig-cache/test-cef-layout-linux";
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, root ++ "/include");
    try cwd.createDirPath(std.testing.io, root ++ "/Release");
    try cwd.createDirPath(std.testing.io, root ++ "/libcef_dll_wrapper");
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/include/cef_app.h", .data = "" });
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/Release/libcef.so", .data = "" });
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/libcef_dll_wrapper/libcef_dll_wrapper.a", .data = "" });

    const report = verifyLayoutFor(std.testing.io, .linux64, root);
    try std.testing.expect(report.ok);
}

test "layout verifier accepts complete windows fixture" {
    const root = ".zig-cache/test-cef-layout-windows";
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, root ++ "/include");
    try cwd.createDirPath(std.testing.io, root ++ "/Release");
    try cwd.createDirPath(std.testing.io, root ++ "/libcef_dll_wrapper");
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/include/cef_app.h", .data = "" });
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/Release/libcef.dll", .data = "" });
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/libcef_dll_wrapper/libcef_dll_wrapper.lib", .data = "" });

    const report = verifyLayoutFor(std.testing.io, .windows64, root);
    try std.testing.expect(report.ok);
}
