const std = @import("std");
const ui_markup = @import("ui_markup");
const markup_lsp = @import("markup_lsp");

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len >= 1 and std.mem.eql(u8, args[0], "lsp")) {
        return runLsp(allocator, io);
    }
    if (args.len < 1 or !std.mem.eql(u8, args[0], "check")) {
        usage();
        return error.MarkupCommandFailed;
    }
    if (args.len < 2) {
        std.debug.print("error: markup check requires a file path\n", .{});
        return error.MarkupCommandFailed;
    }

    var failures: usize = 0;
    for (args[1..]) |file_path| {
        checkFile(allocator, io, file_path) catch {
            failures += 1;
        };
    }
    if (failures > 0) return error.MarkupCheckFailed;
}

fn runLsp(allocator: std.mem.Allocator, io: std.Io) !void {
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    var server = markup_lsp.Server.init(allocator, &stdin_reader.interface, &stdout_writer.interface);
    defer server.deinit();
    try server.run();
}

fn checkFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !void {
    const source = readFile(allocator, io, file_path) catch |err| {
        std.debug.print("error: {s}: unable to read file ({s})\n", .{ file_path, @errorName(err) });
        return err;
    };
    defer allocator.free(source);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var parser = ui_markup.Parser.init(arena_state.allocator(), source);
    const document = parser.parse() catch |err| {
        std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ file_path, parser.diagnostic.line, parser.diagnostic.column, parser.diagnostic.message });
        return err;
    };
    if (ui_markup.validate(document)) |info| {
        std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ file_path, info.line, info.column, info.message });
        return error.MarkupInvalid;
    }
    std.debug.print("{s}: ok\n", .{file_path});
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
}

fn usage() void {
    std.debug.print(
        \\usage: zero-native markup check <file.zml> [more files...]
        \\       zero-native markup lsp
        \\
        \\check: parses and validates markup views: grammar, expression forms,
        \\elements, attributes, and structure tags. Binding paths and message
        \\tags are validated against your Model/Msg when the app builds.
        \\
        \\lsp: speaks the Language Server Protocol over stdio (diagnostics,
        \\completion, hover) for .zml files; wire it into your editor's LSP
        \\client (see editors/zml/README.md).
        \\
    , .{});
}
