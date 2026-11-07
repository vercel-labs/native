const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) {
        std.debug.print("usage: check_file_contains <path> <pattern>\n", .{});
        std.process.exit(2);
    }

    const path = args[1];
    const pattern = args[2];
    const content = std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
        std.debug.print("failed to read {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };

    if (!try containsNormalizedNewlines(allocator, content, pattern)) {
        std.debug.print("missing pattern in {s}: {s}\n", .{ path, pattern });
        std.process.exit(1);
    }
}

fn containsNormalizedNewlines(allocator: std.mem.Allocator, content: []const u8, pattern: []const u8) !bool {
    if (std.mem.indexOf(u8, content, pattern) != null) return true;
    if (std.mem.indexOf(u8, content, "\r\n") == null and std.mem.indexOf(u8, pattern, "\r\n") == null) return false;

    const normalized_content = try normalizeNewlines(allocator, content);
    defer allocator.free(normalized_content);
    const normalized_pattern = try normalizeNewlines(allocator, pattern);
    defer allocator.free(normalized_pattern);
    return std.mem.indexOf(u8, normalized_content, normalized_pattern) != null;
}

fn normalizeNewlines(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var crlf_count: usize = 0;
    var index: usize = 0;
    while (index + 1 < input.len) : (index += 1) {
        if (input[index] == '\r' and input[index + 1] == '\n') crlf_count += 1;
    }

    const normalized = try allocator.alloc(u8, input.len - crlf_count);
    var source: usize = 0;
    var destination: usize = 0;
    while (source < input.len) : (source += 1) {
        if (input[source] == '\r' and source + 1 < input.len and input[source + 1] == '\n') continue;
        normalized[destination] = input[source];
        destination += 1;
    }
    return normalized;
}

test "contains exact content without normalization" {
    try std.testing.expect(try containsNormalizedNewlines(std.testing.allocator, "alpha\nbeta", "alpha"));
    try std.testing.expect(!try containsNormalizedNewlines(std.testing.allocator, "alpha\nbeta", "gamma"));
}

test "contains treats LF and CRLF as equivalent" {
    try std.testing.expect(try containsNormalizedNewlines(std.testing.allocator, "alpha\r\nbeta\r\n", "alpha\nbeta\n"));
    try std.testing.expect(try containsNormalizedNewlines(std.testing.allocator, "alpha\nbeta\n", "alpha\r\nbeta\r\n"));
}

test "contains preserves standalone carriage returns" {
    try std.testing.expect(!try containsNormalizedNewlines(std.testing.allocator, "alpha\rbeta", "alpha\nbeta"));
}
