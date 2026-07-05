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
    // Exit directly: the diagnostics above are the whole story, and a
    // returned error would bury them under the CLI's own return trace.
    if (failures > 0) std.process.exit(1);
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

    // Resolve the import closure from disk, rooted at the checked file's
    // directory (the markup root): checking a view checks its imports, and
    // a broken import reports at the importing file's position. A file
    // that is all templates (no view root) is a valid component file —
    // it checks standalone and as an import target.
    var disk_loader = DiskLoader{ .io = io };
    var diagnostic: ui_markup.MarkupErrorInfo = .{};
    const document = ui_markup.resolveImports(arena_state.allocator(), file_path, source, disk_loader.loader(), &diagnostic) catch |err| {
        const path = if (diagnostic.path.len > 0) diagnostic.path else file_path;
        std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ path, diagnostic.line, diagnostic.column, diagnostic.message });
        printStaleBinaryHint(diagnostic.message);
        return err;
    };
    if (ui_markup.validate(document)) |info| {
        const info_path = if (info.path.len > 0) info.path else file_path;
        // The position-into-source refinements (tofu codepoint, vocabulary
        // suggestion) read the ROOT file's source; an error inside an
        // imported file still reports its own path:line:column.
        const position_in_root = info.path.len == 0 or std.mem.eql(u8, info.path, file_path);
        // The tofu guard's position points at the exact character; name
        // the codepoint so the fix is one glance.
        if (position_in_root and info.message.ptr == ui_markup.font_coverage_message.ptr) {
            if (codepointAt(source, info.line, info.column)) |found| {
                std.debug.print("{s}:{d}:{d}: error: {s} (found \"{s}\" U+{X:0>4})\n", .{ info_path, info.line, info.column, info.message, found.bytes, found.codepoint });
                return error.MarkupInvalid;
            }
        }
        // A vocabulary miss teaches best when it names the token and its
        // nearest valid spelling: the validator's message is a static
        // string, but the checker holds the source and the position.
        if (position_in_root) {
            if (vocabularySuggestion(source, info)) |extra| {
                std.debug.print("{s}:{d}:{d}: error: {s} \"{s}\"", .{ info_path, info.line, info.column, info.message, extra.token });
                if (extra.suggestion) |suggestion| {
                    std.debug.print(" (did you mean \"{s}\"?)\n", .{suggestion});
                } else {
                    std.debug.print("\n", .{});
                }
                printStaleBinaryHint(info.message);
                return error.MarkupInvalid;
            }
        }
        std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ info_path, info.line, info.column, info.message });
        printStaleBinaryHint(info.message);
        return error.MarkupInvalid;
    }
    std.debug.print("{s}: ok\n", .{file_path});
}

/// Import loading for the checker: resolver paths are already joined
/// against the checked file's path, so they read relative to the process
/// cwd exactly like the file argument itself.
const DiskLoader = struct {
    io: std.Io,

    fn loader(self: *DiskLoader) ui_markup.ImportLoader {
        return .{ .context = @ptrCast(self), .load = load };
    }

    fn load(context: *const anyopaque, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const self: *const DiskLoader = @ptrCast(@alignCast(context));
        var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return null;
        defer file.close(self.io);
        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &read_buffer);
        return reader.interface.allocRemaining(arena, .limited(1024 * 1024)) catch null;
    }
};

const VocabularySuggestion = struct { token: []const u8, suggestion: ?[]const u8 };

fn vocabularySuggestion(source: []const u8, info: ui_markup.MarkupErrorInfo) ?VocabularySuggestion {
    // The expression library is a closed vocabulary too: name the unknown
    // function and its nearest valid spelling. The validator's position
    // points at the attribute (or the interpolation's brace), so the
    // offending call sits at or after it on the rest of the source.
    if (std.mem.eql(u8, info.message, ui_markup.expr.unknown_function_message)) {
        const rest = sourceFrom(source, info.line, info.column) orelse return null;
        const token = ui_markup.expr.firstUnknownFunction(rest) orelse return null;
        return .{ .token = token, .suggestion = nearestName(token, &ui_markup.expr.known_function_names) };
    }
    const names: []const []const u8 = if (std.mem.eql(u8, info.message, "unknown attribute"))
        &ui_markup.known_option_attrs
    else if (std.mem.eql(u8, info.message, "unknown element"))
        &ui_markup.known_element_names
    else
        return null;
    const token = tokenAt(source, info.line, info.column) orelse return null;
    return .{ .token = token, .suggestion = nearestName(token, names) };
}

/// The source from a 1-based line/column to the end (columns count bytes,
/// matching the parser's positions).
fn sourceFrom(source: []const u8, line: usize, column: usize) ?[]const u8 {
    if (line == 0 or column == 0) return null;
    var current_line: usize = 1;
    var index: usize = 0;
    while (index < source.len and current_line < line) : (index += 1) {
        if (source[index] == '\n') current_line += 1;
    }
    if (current_line != line) return null;
    const start = index + (column - 1);
    if (start >= source.len) return null;
    return source[start..];
}

/// The identifier ([a-z0-9-_]) starting at a 1-based line/column.
fn tokenAt(source: []const u8, line: usize, column: usize) ?[]const u8 {
    if (line == 0 or column == 0) return null;
    var current_line: usize = 1;
    var index: usize = 0;
    while (index < source.len and current_line < line) : (index += 1) {
        if (source[index] == '\n') current_line += 1;
    }
    if (current_line != line) return null;
    var start = index + (column - 1);
    if (start >= source.len) return null;
    // Element positions point at the "<" itself; the name starts after it.
    if (source[start] == '<') start += 1;
    if (start >= source.len) return null;
    var end = start;
    while (end < source.len) : (end += 1) {
        const c = source[end];
        const identifier = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!identifier) break;
    }
    if (end == start) return null;
    return source[start..end];
}

/// Closest vocabulary name within edit distance 2 - close enough to be a
/// typo, far enough to avoid nonsense suggestions.
fn nearestName(token: []const u8, names: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = 3;
    for (names) |name| {
        const distance = editDistance(token, name) orelse continue;
        if (distance < best_distance) {
            best_distance = distance;
            best = name;
        }
    }
    return best;
}

/// Bounded Levenshtein distance; null when either side is too long for
/// the fixed buffer (vocabulary names are short).
fn editDistance(a: []const u8, b: []const u8) ?usize {
    if (b.len > 63) return null;
    var previous: [64]usize = undefined;
    var current: [64]usize = undefined;
    for (0..b.len + 1) |j| previous[j] = j;
    for (a, 0..) |a_char, i| {
        current[0] = i + 1;
        for (b, 0..) |b_char, j| {
            const substitution_cost: usize = if (a_char == b_char) 0 else 1;
            current[j + 1] = @min(
                previous[j] + substitution_cost,
                @min(current[j] + 1, previous[j + 1] + 1),
            );
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

/// The stale-binary markup-vocabulary case: "unknown element/attribute" from an OLD
/// `native` binary checking NEW syntax looks exactly like an authoring
/// mistake — a stale zig-out binary cost a misdiagnosis round this way.
/// When the diagnosis is a vocabulary miss, say the other explanation
/// out loud.
fn printStaleBinaryHint(message: []const u8) void {
    const vocabulary_miss = std.mem.startsWith(u8, message, "unknown element") or
        std.mem.startsWith(u8, message, "unknown attribute") or
        std.mem.startsWith(u8, message, "unknown event attribute");
    if (!vocabulary_miss) return;
    std.debug.print(
        "       (if this syntax is newer than this binary, your `native` binary may be\n" ++
            "        stale - rebuild it from the current framework checkout and compare\n" ++
            "        `native version`)\n",
        .{},
    );
}

const FoundCodepoint = struct { bytes: []const u8, codepoint: u21 };

/// Decode the codepoint at a 1-based line/column (columns count bytes,
/// matching the parser's positions).
fn codepointAt(source: []const u8, line: usize, column: usize) ?FoundCodepoint {
    if (line == 0 or column == 0) return null;
    var current_line: usize = 1;
    var index: usize = 0;
    while (index < source.len and current_line < line) : (index += 1) {
        if (source[index] == '\n') current_line += 1;
    }
    if (current_line != line) return null;
    const offset = index + (column - 1);
    if (offset >= source.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(source[offset]) catch return null;
    if (offset + len > source.len) return null;
    const codepoint = std.unicode.utf8Decode(source[offset .. offset + len]) catch return null;
    return .{ .bytes = source[offset .. offset + len], .codepoint = codepoint };
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
        \\usage: native markup check <file.zml> [more files...]
        \\       native markup lsp
        \\
        \\check: parses and validates markup views: grammar, expression forms,
        \\elements, attributes, structure tags, imports (checking a view
        \\follows its <import> closure; a file that is all templates is a
        \\valid component file), and font coverage (literal text outside the
        \\bundled face renders as tofu boxes on reference paths - the error
        \\names the character; use icons or plain words). Binding paths and
        \\message tags are validated against your Model/Msg when the app
        \\builds.
        \\
        \\lsp: speaks the Language Server Protocol over stdio (diagnostics,
        \\completion, hover) for .zml files; wire it into your editor's LSP
        \\client (see editors/zml/README.md).
        \\
    , .{});
}
