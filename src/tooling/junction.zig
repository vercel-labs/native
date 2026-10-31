//! Windows directory-junction shim for cross-volume SDK wiring.
//!
//! build.zig.zon path dependencies must be relative to the build root (Zig
//! rejects absolute paths), but on Windows a relative path only exists when
//! both ends share a volume: no chain of `..` segments leads from an app on
//! D:\ to an SDK under the npm global prefix on C:\, nor between two
//! different \\server\share UNC roots. `std.fs.path.relative` signals that
//! case by returning the canonicalized absolute target instead of a
//! relative path. The bridge is a directory junction inside the app's
//! `.native/` directory pointing at the framework root, so the zon
//! dependency can stay relative by routing through it. Junctions — mount
//! points, not file symlinks — resolve on the filesystem like plain
//! directories and, unlike symlinks, need neither Administrator rights nor
//! Developer Mode to create, which is why this shim sets a MOUNT_POINT
//! reparse point instead of calling the symlink API.

const std = @import("std");
const builtin = @import("builtin");

/// True when a path computed by `std.fs.path.relative` could not actually
/// be made relative — the Windows cross-volume case (two drive letters, or
/// two different UNC shares), where the function degrades to the absolute
/// target path. Checks both path flavors so the decision is testable with
/// fabricated `C:\`/`D:\` strings on every host.
pub fn crossesVolumes(dependency_path: []const u8) bool {
    return std.fs.path.isAbsoluteWindows(dependency_path) or
        std.fs.path.isAbsolutePosix(dependency_path);
}

/// The two user-level ways out when the cross-volume junction bridge is
/// unavailable or does not apply (appended to every cross-volume teaching
/// error, so no failure ever ends at "absolute paths are rejected" without
/// a way forward).
pub const cross_volume_ways_out =
    \\Two ways out:
    \\  - keep the app on the same volume as the Native SDK install, or
    \\  - move the npm global prefix onto the app's volume
    \\    (`npm config set prefix <dir on the app's volume>`, then
    \\    reinstall @native-sdk/cli there).
    \\
;

pub const EnsureError = error{
    /// Junctions are a Windows (NTFS reparse point) concept; on other
    /// platforms a genuinely relative path always exists and this shim is
    /// never needed.
    UnsupportedPlatform,
    /// The reparse point could not be created (exotic filesystem, policy).
    /// Callers must turn this into a teaching error, never into an
    /// absolute zon path.
    JunctionFailed,
    /// Something that is not a junction (a non-empty real directory)
    /// occupies the junction path; refusing beats silently deleting a tree
    /// the CLI does not own.
    JunctionPathOccupied,
} || std.mem.Allocator.Error || std.Io.Cancelable;

/// Make `junction_path` a directory junction resolving to `target` (both
/// absolute, symlink-free paths — realpath output). Idempotent per
/// generation: a junction already resolving to `target` is left untouched
/// (so repeated `native dev|build|test` runs are no-ops), one resolving
/// elsewhere (the SDK moved or was upgraded in place) or dangling (its old
/// target was deleted) is removed and recreated.
pub fn ensure(allocator: std.mem.Allocator, io: std.Io, junction_path: []const u8, target: []const u8) EnsureError!void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

    const cwd = std.Io.Dir.cwd();
    if (cwd.realPathFileAlloc(io, junction_path, allocator)) |resolved| {
        defer allocator.free(resolved);
        // Windows paths are case-insensitive; compare that way so a mere
        // case difference between two realpath spellings never causes a
        // delete/recreate cycle on every generation.
        if (std.ascii.eqlIgnoreCase(resolved, target)) return;
    } else |err| switch (err) {
        error.Canceled => |e| return e,
        // Missing entirely, or a junction whose target no longer exists
        // (realpath cannot resolve through it) — either way, fall through
        // and clear the name so creation below starts fresh.
        else => {},
    }

    remove(io, junction_path) catch |err| switch (err) {
        error.JunctionNotFound => {},
        else => |e| return e,
    };

    create(io, junction_path, target) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {
            // A half-made junction is a plain empty directory; clear it so
            // the next attempt (or a user retry) starts from nothing.
            cwd.deleteDir(io, junction_path) catch {};
            return error.JunctionFailed;
        },
    };
}

/// Delete whatever occupies `junction_path` without ever touching a
/// junction's target: RemoveDirectory deletes the reparse point itself
/// (dangling or not) and also clears a plain empty directory, while a
/// non-empty real directory fails DirNotEmpty — surfaced as occupied
/// rather than destroying data the CLI does not own.
fn remove(io: std.Io, junction_path: []const u8) error{ JunctionNotFound, JunctionPathOccupied, Canceled }!void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteDir(io, junction_path) catch |err| switch (err) {
        error.FileNotFound => return error.JunctionNotFound,
        error.Canceled => |e| return e,
        // A regular file squatting on the name: clear it the file way.
        error.NotDir => cwd.deleteFile(io, junction_path) catch |file_err| switch (file_err) {
            error.FileNotFound => return error.JunctionNotFound,
            error.Canceled => |e| return e,
            else => return error.JunctionPathOccupied,
        },
        else => return error.JunctionPathOccupied,
    };
}

/// Create the junction: make the directory and set a MOUNT_POINT reparse
/// point on it in one NtCreateFile + FSCTL_SET_REPARSE_POINT pair, the same
/// operation `mklink /J` performs. The substitute name is the NT-namespaced
/// target (`\??\C:\...`), the print name its Win32 spelling for `dir`
/// output.
fn create(io: std.Io, junction_path: []const u8, target: []const u8) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const w = std.os.windows;

    const junction_nt = try std.Io.Threaded.sliceToPrefixedFileW(null, junction_path, .{ .allow_relative = false });
    const target_nt = try std.Io.Threaded.sliceToPrefixedFileW(null, target, .{ .allow_relative = false });
    const substitute = target_nt.span();

    var print_buffer: [w.PATH_MAX_WIDE]u16 = undefined;
    // An empty print name is valid reparse data; the junction still
    // resolves, it just lists without a pretty target in Explorer/`dir`.
    const print_name: []const u16 = w.ntToWin32Namespace(substitute, &print_buffer) catch &.{};

    // REPARSE_DATA_BUFFER header for IO_REPARSE_TAG_MOUNT_POINT, followed
    // by PathBuffer holding substitute + NUL + print + NUL (WTF-16).
    const MountPointData = extern struct {
        ReparseTag: w.IO_REPARSE_TAG,
        ReparseDataLength: w.USHORT,
        Reserved: w.USHORT,
        SubstituteNameOffset: w.USHORT,
        SubstituteNameLength: w.USHORT,
        PrintNameOffset: w.USHORT,
        PrintNameLength: w.USHORT,
    };
    var buffer: [w.MAXIMUM_REPARSE_DATA_BUFFER_SIZE]u8 = undefined;
    const substitute_bytes = substitute.len * 2;
    const print_bytes = print_name.len * 2;
    const total_len = @sizeOf(MountPointData) + substitute_bytes + 2 + print_bytes + 2;
    if (total_len > buffer.len) return error.NameTooLong;
    const header: MountPointData = .{
        .ReparseTag = .MOUNT_POINT,
        // Everything after the 8-byte (tag + length + reserved) prefix.
        .ReparseDataLength = @intCast(total_len - 8),
        .Reserved = 0,
        .SubstituteNameOffset = 0,
        .SubstituteNameLength = @intCast(substitute_bytes),
        .PrintNameOffset = @intCast(substitute_bytes + 2),
        .PrintNameLength = @intCast(print_bytes),
    };
    @memcpy(buffer[0..@sizeOf(MountPointData)], std.mem.asBytes(&header));
    var offset: usize = @sizeOf(MountPointData);
    @memcpy(buffer[offset..][0..substitute_bytes], std.mem.sliceAsBytes(substitute));
    offset += substitute_bytes;
    buffer[offset] = 0;
    buffer[offset + 1] = 0;
    offset += 2;
    @memcpy(buffer[offset..][0..print_bytes], std.mem.sliceAsBytes(print_name));
    offset += print_bytes;
    buffer[offset] = 0;
    buffer[offset + 1] = 0;

    // Create the directory and keep a synchronous write handle to it that
    // does not follow reparse points — the handle FSCTL_SET_REPARSE_POINT
    // stamps the mount point onto.
    var handle: w.HANDLE = undefined;
    const attr: w.OBJECT.ATTRIBUTES = .{
        .RootDirectory = null,
        .ObjectName = @constCast(&w.UNICODE_STRING.init(junction_nt.span())),
    };
    var iosb: w.IO_STATUS_BLOCK = undefined;
    switch (w.ntdll.NtCreateFile(
        &handle,
        .{ .GENERIC = .{ .WRITE = true }, .STANDARD = .{ .SYNCHRONIZE = true } },
        &attr,
        &iosb,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .CREATE,
        .{ .DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = true },
        null,
        0,
    )) {
        .SUCCESS => {},
        .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
        .ACCESS_DENIED => return error.AccessDenied,
        else => return error.JunctionFailed,
    }
    defer w.CloseHandle(handle);

    const result = try io.operate(.{ .device_io_control = .{
        .file = .{ .handle = handle, .flags = .{ .nonblocking = false } },
        .code = .SET_REPARSE_POINT,
        .in = buffer[0..total_len],
    } });
    if (result.device_io_control.u.Status != .SUCCESS) return error.JunctionFailed;
}

test "cross-volume detection catches what std.fs.path.relative degrades to" {
    // Same volume: a genuinely relative result, no junction needed.
    try std.testing.expect(!crossesVolumes("../../.."));
    try std.testing.expect(!crossesVolumes("..\\..\\sdk"));
    try std.testing.expect(!crossesVolumes(""));
    // Cross volume on Windows: relative() returns the absolute target.
    try std.testing.expect(crossesVolumes("C:\\Users\\alpha\\AppData\\Roaming\\npm\\node_modules\\@native-sdk\\cli"));
    try std.testing.expect(crossesVolumes("\\\\server\\share\\native-sdk"));
    // POSIX absolute cannot happen from relative(), but stays covered.
    try std.testing.expect(crossesVolumes("/opt/native-sdk"));
}

test "the reported cross-drive layout degrades to an absolute path and is detected" {
    // The exact shape from the field report: app on D:\, npm-global SDK on
    // C:\ — relativeWindows is pure, so this runs on every host.
    const dependency_path = try std.fs.path.relativeWindows(
        std.testing.allocator,
        "D:\\Projects\\my_app",
        null,
        "D:\\Projects\\my_app\\.native\\build",
        "C:\\Users\\alpha\\AppData\\Roaming\\npm\\node_modules\\@native-sdk\\cli",
    );
    defer std.testing.allocator.free(dependency_path);
    try std.testing.expect(std.fs.path.isAbsoluteWindows(dependency_path));
    try std.testing.expect(crossesVolumes(dependency_path));

    // Control: same drive stays relative and is not routed.
    const same_drive = try std.fs.path.relativeWindows(
        std.testing.allocator,
        "D:\\Projects\\my_app",
        null,
        "D:\\Projects\\my_app\\.native\\build",
        "D:\\tools\\native-sdk",
    );
    defer std.testing.allocator.free(same_drive);
    try std.testing.expect(!crossesVolumes(same_drive));
}
