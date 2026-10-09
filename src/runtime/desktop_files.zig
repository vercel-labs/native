//! Explicit bounded desktop capabilities. App policy stays in the compiled core.
const std = @import("std");
const builtin = @import("builtin");
pub const max_items = 512;
pub const max_path_bytes = 1024;

pub fn isName(name: []const u8) bool {
    return std.mem.eql(u8, name, "native-sdk.dialog.openDirectory") or
        std.mem.eql(u8, name, "native-sdk.fs.listDirectory") or
        std.mem.eql(u8, name, "native-sdk.fs.renameExclusive") or
        std.mem.eql(u8, name, "native-sdk.window.focusResult") or
        std.mem.eql(u8, name, "native-sdk.window.closeResult");
}

pub const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    pub fn word(self: *Reader) !u16 {
        if (self.at > self.bytes.len or self.bytes.len - self.at < 2) return error.InvalidRequest;
        const value = std.mem.readInt(u16, self.bytes[self.at..][0..2], .little);
        self.at += 2;
        return value;
    }
    pub fn field(self: *Reader) ![]const u8 {
        const len = try self.word();
        if (self.at > self.bytes.len or len > self.bytes.len - self.at) return error.InvalidRequest;
        const value = self.bytes[self.at..][0..len];
        self.at += len;
        return value;
    }
    pub fn finish(self: *Reader) !void {
        if (self.at != self.bytes.len) return error.InvalidRequest;
    }
};

pub fn request(payload: []const u8) !Reader {
    if (payload.len < 2) return error.InvalidRequest;
    if (payload[0] == 1) return .{ .bytes = payload, .at = 2 };
    if (payload[0] != 2 or payload.len < 4) return error.InvalidRequest;
    const context_len = std.mem.readInt(u16, payload[2..4], .little);
    if (context_len == 0 or context_len > 32 or context_len > payload.len - 4) return error.InvalidRequest;
    return .{ .bytes = payload, .at = 4 + context_len };
}
/// Echo opaque application correlation bytes without interpreting their policy.
pub fn replyHeaderFor(output: []u8, payload: []const u8, failure: []const u8) !usize {
    const reader = try request(payload);
    if (payload[0] == 1) return replyHeader(output, payload[1], failure);
    const prefix = reader.at;
    if (failure.len > 65535 or output.len < prefix + 2 or failure.len > output.len - prefix - 2) return error.OverBound;
    @memcpy(output[0..prefix], payload[0..prefix]);
    std.mem.writeInt(u16, output[prefix..][0..2], @intCast(failure.len), .little);
    @memcpy(output[prefix + 2 ..][0..failure.len], failure);
    return prefix + 2 + failure.len;
}
pub fn replyHeader(output: []u8, context: u8, failure: []const u8) !usize {
    if (failure.len > 65535 or output.len < 4 or failure.len > output.len - 4) return error.OverBound;
    output[0] = 1;
    output[1] = context;
    std.mem.writeInt(u16, output[2..4], @intCast(failure.len), .little);
    @memcpy(output[4..][0..failure.len], failure);
    return 4 + failure.len;
}
pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > max_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidRequest;
}

pub fn execute(io: std.Io, name: []const u8, payload: []const u8, output: []u8) ![]const u8 {
    var reader = try request(payload);
    if (std.mem.eql(u8, name, "native-sdk.fs.listDirectory")) {
        const capacity = try reader.word();
        const name_limit = try reader.word();
        const path = try reader.field();
        try reader.finish();
        try validatePath(path);
        if (capacity > max_items or name_limit > 255) return error.InvalidRequest;
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
            return output[0..try replyHeaderFor(output, payload, @errorName(err))];
        };
        defer dir.close(io);
        const header = try replyHeaderFor(output, payload, "");
        if (output.len - header < 3) return error.OverBound;
        var at = header + 3;
        var flags: u8 = 0;
        var count: u16 = 0;
        var iterator = dir.iterate();
        while (true) {
            const maybe_entry = iterator.next(io) catch {
                flags |= 2;
                break;
            };
            const entry = maybe_entry orelse break;
            if (count == capacity) {
                flags |= 1;
                break;
            }
            if (entry.name.len > name_limit) {
                flags |= 2;
                continue;
            }
            if (output.len - at < 3 or entry.name.len > output.len - at - 3) return error.OverBound;
            output[at] = @intFromBool(entry.kind == .directory);
            std.mem.writeInt(u16, output[at + 1 ..][0..2], @intCast(entry.name.len), .little);
            @memcpy(output[at + 3 ..][0..entry.name.len], entry.name);
            at += 3 + entry.name.len;
            count += 1;
        }
        output[header] = flags;
        std.mem.writeInt(u16, output[header + 1 ..][0..2], count, .little);
        return output[0..at];
    }
    if (std.mem.eql(u8, name, "native-sdk.fs.renameExclusive")) {
        const old_path = try reader.field();
        const new_path = try reader.field();
        try reader.finish();
        try validatePath(old_path);
        try validatePath(new_path);
        renameExclusive(io, old_path, new_path) catch |err| {
            return output[0..try replyHeaderFor(output, payload, @errorName(err))];
        };
        return output[0..try replyHeaderFor(output, payload, "")];
    }
    return error.Unsupported;
}

fn caseOnlySourceAlias(io: std.Io, old_path: []const u8, new_path: []const u8) bool {
    const old_name = std.fs.path.basename(old_path);
    const new_name = std.fs.path.basename(new_path);
    if (std.mem.eql(u8, old_name, new_name) or !std.ascii.eqlIgnoreCase(old_name, new_name)) return false;
    var old_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var new_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    const old_len = cwd.realPathFile(io, old_path, &old_storage) catch return false;
    const new_len = cwd.realPathFile(io, new_path, &new_storage) catch return false;
    return std.mem.eql(u8, old_storage[0..old_len], new_storage[0..new_len]);
}

pub fn renameExclusive(io: std.Io, old_path: []const u8, new_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (caseOnlySourceAlias(io, old_path, new_path)) return cwd.rename(old_path, cwd, new_path, io);
    if (builtin.os.tag != .macos) return cwd.renamePreserve(old_path, cwd, new_path, io);
    const Darwin = struct {
        extern "c" fn renameatx_np(std.posix.fd_t, [*:0]const u8, std.posix.fd_t, [*:0]const u8, c_uint) c_int;
    };
    const from = try std.posix.toPosixPath(old_path);
    const to = try std.posix.toPosixPath(new_path);
    try io.checkCancel();
    while (true) switch (std.c.errno(Darwin.renameatx_np(cwd.handle, &from, cwd.handle, &to, 0x00000004))) {
        .SUCCESS => return,
        .INTR => try io.checkCancel(),
        .EXIST, .NOTEMPTY => return error.PathAlreadyExists,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .BUSY, .TXTBSY => return error.FileBusy,
        .DQUOT => return error.DiskQuota,
        .IO => return error.HardwareFailure,
        .ISDIR => return error.IsDir,
        .LOOP => return error.SymLinkLoop,
        .MLINK => return error.LinkQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.NoSpaceLeft,
        .OPNOTSUPP => return error.OperationUnsupported,
        .ROFS => return error.ReadOnlyFileSystem,
        .XDEV => return error.CrossDevice,
        .NODEV => return error.NoDevice,
        .CANCELED => return error.Canceled,
        .ILSEQ => return error.BadPathName,
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

test "exclusive rename retains a destination created after enumeration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "old", .data = "source" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "new", .data = "destination" });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const old = try std.fs.path.join(std.testing.allocator, &.{ root_buffer[0..root_len], "old" });
    defer std.testing.allocator.free(old);
    const new = try std.fs.path.join(std.testing.allocator, &.{ root_buffer[0..root_len], "new" });
    defer std.testing.allocator.free(new);
    try std.testing.expectError(error.PathAlreadyExists, renameExclusive(std.testing.io, old, new));
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "new", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("destination", bytes);
}
