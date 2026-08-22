const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) {
        std.debug.print("usage: check_file_exists <path>\n", .{});
        std.process.exit(2);
    }

    if (!fileExists(std.Io.Dir.cwd(), init.io, args[1])) {
        std.debug.print("missing file: {s}\n", .{args[1]});
        std.process.exit(1);
    }
}

fn fileExists(dir: std.Io.Dir, io: std.Io, path: []const u8) bool {
    const stat = dir.statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

test "file existence distinguishes files from missing paths and directories" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expect(!fileExists(tmp.dir, io, "artifact.bin"));
    var file = try tmp.dir.createFile(io, "artifact.bin", .{});
    file.close(io);
    try std.testing.expect(fileExists(tmp.dir, io, "artifact.bin"));

    try tmp.dir.createDir(io, "artifact-dir", .default_dir);
    try std.testing.expect(!fileExists(tmp.dir, io, "artifact-dir"));
}
