const std = @import("std");
const crash_options = @import("file_crash_options");

test "hard process death before streamed close leaves the installed file untouched" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "export.bin", .data = "previous complete generation" });

    var destination_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var ready_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const destination = try std.fmt.bufPrint(&destination_storage, ".zig-cache/tmp/{s}/export.bin", .{tmp.sub_path[0..]});
    const ready = try std.fmt.bufPrint(&ready_storage, ".zig-cache/tmp/{s}/ready", .{tmp.sub_path[0..]});
    var child = try std.process.spawn(io, .{
        .argv = &.{ crash_options.helper_executable, destination, ready },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    defer child.kill(io);

    var waited_ms: usize = 0;
    while (waited_ms < 20_000) : (waited_ms += 10) {
        if (tmp.dir.openFile(io, "ready", .{})) |file_value| {
            var file = file_value;
            file.close(io);
            break;
        } else |_| {}
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
    if (waited_ms == 20_000) return error.TestTimedOut;
    child.kill(io);

    const visible = try tmp.dir.readFileAlloc(io, "export.bin", std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqualStrings("previous complete generation", visible);
}
