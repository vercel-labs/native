//! Startup asset reads shared by generated app runners.
//!
//! Relative paths keep their app-directory meaning during development. In a
//! packaged macOS app, the same tree lives below `Contents/Resources`; Finder
//! and `open` do not preserve a useful working directory, so resolve that tree
//! from the executable's bundle layout before reading it.

const std = @import("std");
const builtin = @import("builtin");

pub fn readFileAlloc(
    io: std.Io,
    path: []const u8,
    allocator: std.mem.Allocator,
    limit: std.Io.Limit,
) std.Io.Dir.ReadFileAllocError![]u8 {
    if (comptime builtin.os.tag == .macos) {
        var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const executable_len = std.process.executablePath(io, &executable_buffer) catch
            return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
        return readFileAllocFromMacosExecutable(
            io,
            executable_buffer[0..executable_len],
            path,
            allocator,
            limit,
        );
    }

    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
}

pub fn readFileAllocFromMacosExecutable(
    io: std.Io,
    executable_path: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,
    limit: std.Io.Limit,
) std.Io.Dir.ReadFileAllocError![]u8 {
    var bundled_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (macosBundleResourcePath(executable_path, path, &bundled_path_buffer) catch null) |bundled_path| {
        return std.Io.Dir.cwd().readFileAlloc(io, bundled_path, allocator, limit) catch |err| switch (err) {
            // Match the platform host's asset resolver: a package miss keeps
            // the old cwd-relative behavior, while a real read failure is not
            // hidden by a second lookup.
            error.FileNotFound => std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit),
            else => |read_err| read_err,
        };
    }
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
}

pub fn macosBundleResourcePath(
    executable_path: []const u8,
    asset_path: []const u8,
    output: []u8,
) error{NoSpaceLeft}!?[]const u8 {
    if (asset_path.len == 0 or std.fs.path.isAbsolutePosix(asset_path)) return null;

    const executable_dir = std.fs.path.dirnamePosix(executable_path) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basenamePosix(executable_dir), "MacOS")) return null;

    const contents_dir = std.fs.path.dirnamePosix(executable_dir) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basenamePosix(contents_dir), "Contents")) return null;

    const bundle_dir = std.fs.path.dirnamePosix(contents_dir) orelse return null;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(bundle_dir), ".app")) return null;

    return std.fmt.bufPrint(output, "{s}/Resources/{s}", .{ contents_dir, asset_path }) catch
        error.NoSpaceLeft;
}

test "macOS bundle resource path mirrors the app-relative asset tree" {
    var buffer: [256]u8 = undefined;
    const resolved = (try macosBundleResourcePath(
        "/Applications/Kanban.app/Contents/MacOS/kanban",
        "assets/logos/openai-svgl.png",
        &buffer,
    )).?;
    try std.testing.expectEqualStrings(
        "/Applications/Kanban.app/Contents/Resources/assets/logos/openai-svgl.png",
        resolved,
    );

    const uppercase = (try macosBundleResourcePath(
        "/Applications/Kanban.APP/Contents/MacOS/kanban",
        "assets/logo.png",
        &buffer,
    )).?;
    try std.testing.expectEqualStrings(
        "/Applications/Kanban.APP/Contents/Resources/assets/logo.png",
        uppercase,
    );

    try std.testing.expectEqual(null, try macosBundleResourcePath(
        "/tmp/kanban",
        "assets/logo.png",
        &buffer,
    ));
    try std.testing.expectEqual(null, try macosBundleResourcePath(
        "/Applications/Kanban.app/Contents/Helpers/kanban",
        "assets/logo.png",
        &buffer,
    ));
    try std.testing.expectEqual(null, try macosBundleResourcePath(
        "/Applications/Kanban.app/Contents/MacOS/kanban",
        "/tmp/logo.png",
        &buffer,
    ));
}

test "packaged macOS startup assets read from Contents Resources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const resource_dir = "Kanban.app/Contents/Resources/assets/logos";
    try tmp.dir.createDirPath(std.testing.io, resource_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = resource_dir ++ "/openai.png",
        .data = "packaged-avatar",
    });

    var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_path = try std.fmt.bufPrint(
        &executable_buffer,
        ".zig-cache/tmp/{s}/Kanban.app/Contents/MacOS/kanban",
        .{tmp.sub_path[0..]},
    );
    const bytes = try readFileAllocFromMacosExecutable(
        std.testing.io,
        executable_path,
        "assets/logos/openai.png",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("packaged-avatar", bytes);
}
