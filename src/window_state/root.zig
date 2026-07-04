const std = @import("std");
const app_dirs = @import("app_dirs");
const geometry = @import("geometry");
const platform = @import("../platform/root.zig");

pub const Error = error{
    NoSpaceLeft,
    InvalidState,
};

pub const max_serialized_bytes: usize = 64 * 1024;

/// Targets with no filesystem (freestanding wasm docs previews) skip
/// persistence entirely — the same honest degradation the runtime
/// clocks use on wasi. Comptime-known so `std.Io.Dir.cwd()` (posix)
/// never gets analyzed on those targets.
const has_filesystem = switch (@import("builtin").os.tag) {
    .freestanding, .emscripten => false,
    else => true,
};

pub const Store = struct {
    io: std.Io,
    state_dir: []const u8,
    file_path: []const u8,

    pub fn init(io: std.Io, state_dir: []const u8, file_path: []const u8) Store {
        return .{ .io = io, .state_dir = state_dir, .file_path = file_path };
    }

    pub fn loadWindow(self: Store, label: []const u8, buffer: []u8) !?platform.WindowState {
        const bytes = readPath(self.io, self.file_path, buffer) catch return null;
        return parseWindowInto(bytes, label, buffer[bytes.len..]);
    }

    pub fn loadWindows(self: Store, output: []platform.WindowState, buffer: []u8) ![]platform.WindowState {
        const bytes = readPath(self.io, self.file_path, buffer) catch return output[0..0];
        return parseWindowsInto(bytes, output, buffer[bytes.len..]);
    }

    pub fn saveWindow(self: Store, state: platform.WindowState) !void {
        if (!has_filesystem) return;
        if (state.label.len == 0) return;
        var cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.state_dir);
        var read_buffer: [max_serialized_bytes]u8 = undefined;
        var windows_buffer: [platform.max_windows]platform.WindowState = undefined;
        var windows = self.loadWindows(&windows_buffer, &read_buffer) catch windows_buffer[0..0];
        var found = false;
        for (windows) |*window| {
            if ((state.label.len > 0 and std.mem.eql(u8, window.label, state.label)) or (state.id != 0 and window.id == state.id)) {
                window.* = state;
                found = true;
                break;
            }
        }
        var merged: [platform.max_windows]platform.WindowState = undefined;
        const existing_count = @min(windows.len, merged.len);
        @memcpy(merged[0..existing_count], windows[0..existing_count]);
        var count = existing_count;
        if (!found and count < merged.len) {
            merged[count] = state;
            count += 1;
        }
        var buffer: [max_serialized_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writeWindows(merged[0..count], &writer);
        try cwd.writeFile(self.io, .{ .sub_path = self.file_path, .data = writer.buffered() });
    }
};

pub fn defaultPaths(output_dir: []u8, output_file: []u8, app_name: []const u8, env: app_dirs.Env) !StorePaths {
    const platform_value = app_dirs.currentPlatform();
    const state_dir = try app_dirs.resolveOne(.{ .name = app_name }, platform_value, env, .state, output_dir);
    const file_path = try app_dirs.join(platform_value, output_file, &.{ state_dir, "windows.zon" });
    return .{ .state_dir = state_dir, .file_path = file_path };
}

pub const StorePaths = struct {
    state_dir: []const u8,
    file_path: []const u8,
};

pub fn writeWindows(windows: []const platform.WindowState, writer: anytype) !void {
    try writer.writeAll(".{\n  .windows = .{\n");
    for (windows) |window| {
        try writer.print("    .{{ .id = {d}, .label = ", .{window.id});
        try writeZonString(writer, window.label);
        try writer.writeAll(", .title = ");
        try writeZonString(writer, window.title);
        try writer.print(
            ", .open = {any}, .focused = {any}, .x = {d}, .y = {d}, .width = {d}, .height = {d}, .scale = {d}, .maximized = {any}, .fullscreen = {any} }},\n",
            .{
                window.open,
                window.focused,
                window.frame.x,
                window.frame.y,
                window.frame.width,
                window.frame.height,
                window.scale_factor,
                window.maximized,
                window.fullscreen,
            },
        );
    }
    try writer.writeAll("  },\n}\n");
}

pub fn parseWindow(bytes: []const u8, label: []const u8) ?platform.WindowState {
    var storage = StringStorage{ .buffer = &.{} };
    return parseWindowWithStorage(bytes, label, &storage);
}

pub fn parseWindowInto(bytes: []const u8, label: []const u8, storage_buffer: []u8) ?platform.WindowState {
    var storage = StringStorage{ .buffer = storage_buffer };
    return parseWindowWithStorage(bytes, label, &storage);
}

fn parseWindowWithStorage(bytes: []const u8, label: []const u8, storage: *StringStorage) ?platform.WindowState {
    if (label.len == 0) return null;
    var index: usize = 0;
    while (true) {
        const label_field = std.mem.indexOfPos(u8, bytes, index, ".label") orelse return null;
        const record_start = findRecordStart(bytes, label_field) orelse return null;
        const record_end = findRecordEnd(bytes, label_field) orelse return null;
        const record = bytes[record_start..record_end];
        const checkpoint = storage.index;
        const record_label = parseStringField(record, ".label", storage) orelse {
            storage.index = checkpoint;
            index = record_end + 1;
            continue;
        };
        if (record_label.len == 0) {
            storage.index = checkpoint;
            index = record_end + 1;
            continue;
        }
        if (std.mem.eql(u8, record_label, label)) return parseRecord(record, record_label, storage);
        storage.index = checkpoint;
        index = record_end + 1;
    }
}

fn parseStringField(record: []const u8, field: []const u8, storage: *StringStorage) ?[]const u8 {
    const field_index = std.mem.indexOf(u8, record, field) orelse return null;
    const equals = std.mem.indexOfScalarPos(u8, record, field_index, '=') orelse return null;
    const start_quote = std.mem.indexOfScalarPos(u8, record, equals, '"') orelse return null;
    return (parseStringLiteral(record, start_quote, storage) orelse return null).value;
}

fn parseIntField(record: []const u8, field: []const u8) ?platform.WindowId {
    const field_index = std.mem.indexOf(u8, record, field) orelse return null;
    const equals = std.mem.indexOfScalarPos(u8, record, field_index, '=') orelse return null;
    var start = equals + 1;
    while (start < record.len and record[start] == ' ') : (start += 1) {}
    var end = start;
    while (end < record.len and std.ascii.isDigit(record[end])) : (end += 1) {}
    return std.fmt.parseUnsigned(platform.WindowId, record[start..end], 10) catch null;
}

pub fn parseWindows(bytes: []const u8, output: []platform.WindowState) []platform.WindowState {
    var storage = StringStorage{ .buffer = &.{} };
    return parseWindowsWithStorage(bytes, output, &storage);
}

pub fn parseWindowsInto(bytes: []const u8, output: []platform.WindowState, storage_buffer: []u8) []platform.WindowState {
    var storage = StringStorage{ .buffer = storage_buffer };
    return parseWindowsWithStorage(bytes, output, &storage);
}

fn parseWindowsWithStorage(bytes: []const u8, output: []platform.WindowState, storage: *StringStorage) []platform.WindowState {
    var count: usize = 0;
    var index: usize = 0;
    while (count < output.len) {
        const label_field = std.mem.indexOfPos(u8, bytes, index, ".label") orelse break;
        const record_start = findRecordStart(bytes, label_field) orelse break;
        const record_end = findRecordEnd(bytes, label_field) orelse break;
        const record = bytes[record_start..record_end];
        const checkpoint = storage.index;
        const label = parseStringField(record, ".label", storage) orelse {
            storage.index = checkpoint;
            index = record_end + 1;
            continue;
        };
        if (label.len == 0) {
            storage.index = checkpoint;
            index = record_end + 1;
            continue;
        }
        output[count] = parseRecord(record, label, storage);
        count += 1;
        index = record_end + 1;
    }
    return output[0..count];
}

fn parseRecord(record: []const u8, label: []const u8, storage: *StringStorage) platform.WindowState {
    return .{
        .id = parseIntField(record, ".id") orelse 0,
        .label = label,
        .title = parseStringField(record, ".title", storage) orelse "",
        .open = parseBoolField(record, ".open") orelse true,
        .focused = parseBoolField(record, ".focused") orelse false,
        .frame = geometry.RectF.init(
            parseFloatField(record, ".x") orelse 0,
            parseFloatField(record, ".y") orelse 0,
            parseFloatField(record, ".width") orelse 720,
            parseFloatField(record, ".height") orelse 480,
        ),
        .scale_factor = parseFloatField(record, ".scale") orelse 1,
        .maximized = parseBoolField(record, ".maximized") orelse false,
        .fullscreen = parseBoolField(record, ".fullscreen") orelse false,
    };
}

fn parseFloatField(record: []const u8, field: []const u8) ?f32 {
    const field_index = std.mem.indexOf(u8, record, field) orelse return null;
    const equals = std.mem.indexOfScalarPos(u8, record, field_index, '=') orelse return null;
    var start = equals + 1;
    while (start < record.len and record[start] == ' ') : (start += 1) {}
    var end = start;
    while (end < record.len and (std.ascii.isDigit(record[end]) or record[end] == '.' or record[end] == '-')) : (end += 1) {}
    return std.fmt.parseFloat(f32, record[start..end]) catch null;
}

fn parseBoolField(record: []const u8, field: []const u8) ?bool {
    const field_index = std.mem.indexOf(u8, record, field) orelse return null;
    const equals = std.mem.indexOfScalarPos(u8, record, field_index, '=') orelse return null;
    var start = equals + 1;
    while (start < record.len and record[start] == ' ') : (start += 1) {}
    if (std.mem.startsWith(u8, record[start..], "true")) return true;
    if (std.mem.startsWith(u8, record[start..], "false")) return false;
    return null;
}

const ParsedString = struct {
    value: []const u8,
};

const StringStorage = struct {
    buffer: []u8,
    index: usize = 0,

    fn append(self: *StringStorage, bytes: []const u8) bool {
        if (self.index + bytes.len > self.buffer.len) return false;
        @memcpy(self.buffer[self.index..][0..bytes.len], bytes);
        self.index += bytes.len;
        return true;
    }

    fn appendByte(self: *StringStorage, byte: u8) bool {
        if (self.index >= self.buffer.len) return false;
        self.buffer[self.index] = byte;
        self.index += 1;
        return true;
    }
};

fn writeZonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11...12, 14...0x1f => try writer.print("\\x{x:0>2}", .{ch}),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

fn parseStringLiteral(bytes: []const u8, start_quote: usize, storage: *StringStorage) ?ParsedString {
    if (start_quote >= bytes.len or bytes[start_quote] != '"') return null;
    var index = start_quote + 1;
    var segment_start = index;
    var copied = false;
    var output_start: usize = storage.index;

    while (index < bytes.len) {
        const ch = bytes[index];
        if (ch == '"') {
            if (!copied) return .{ .value = bytes[segment_start..index] };
            if (!storage.append(bytes[segment_start..index])) return null;
            return .{ .value = storage.buffer[output_start..storage.index] };
        }
        if (ch <= 0x1f) return null;
        if (ch != '\\') {
            index += 1;
            continue;
        }

        if (!copied) {
            copied = true;
            output_start = storage.index;
        }
        if (!storage.append(bytes[segment_start..index])) return null;

        index += 1;
        if (index >= bytes.len) return null;
        const escaped = bytes[index];
        switch (escaped) {
            '"' => {
                if (!storage.appendByte('"')) return null;
                index += 1;
            },
            '\\' => {
                if (!storage.appendByte('\\')) return null;
                index += 1;
            },
            'n' => {
                if (!storage.appendByte('\n')) return null;
                index += 1;
            },
            'r' => {
                if (!storage.appendByte('\r')) return null;
                index += 1;
            },
            't' => {
                if (!storage.appendByte('\t')) return null;
                index += 1;
            },
            'x' => {
                if (index + 2 >= bytes.len) return null;
                const high = hexValue(bytes[index + 1]) orelse return null;
                const low = hexValue(bytes[index + 2]) orelse return null;
                if (!storage.appendByte((high << 4) | low)) return null;
                index += 3;
            },
            else => return null,
        }
        segment_start = index;
    }
    return null;
}

fn findRecordStart(bytes: []const u8, label_pos: usize) ?usize {
    var i = label_pos;
    while (i > 0) {
        i -= 1;
        if (bytes[i] == '{') return i;
    }
    return null;
}

fn findRecordEnd(bytes: []const u8, start: usize) ?usize {
    var index = start;
    var in_string = false;
    var escaped = false;
    while (index < bytes.len) : (index += 1) {
        const ch = bytes[index];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        if (ch == '"') {
            in_string = true;
        } else if (ch == '}') {
            return index;
        }
    }
    return null;
}

fn hexValue(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

fn readPath(io: std.Io, path: []const u8, buffer: []u8) ![]const u8 {
    if (!has_filesystem) return error.InvalidState;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return buffer[0..try file.readPositionalAll(io, buffer, 0)];
}

test "window state writes and parses named records" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeWindows(&.{
        .{ .id = 1, .label = "main", .frame = geometry.RectF.init(10, 20, 800, 600), .scale_factor = 2 },
        .{ .id = 2, .label = "settings", .frame = geometry.RectF.init(30, 40, 500, 400), .open = false },
    }, &writer);

    const main = parseWindow(writer.buffered(), "main").?;
    try std.testing.expectEqualStrings("main", main.label);
    try std.testing.expectEqual(@as(u64, 1), main.id);
    try std.testing.expectEqual(@as(f32, 10), main.frame.x);
    try std.testing.expectEqual(@as(f32, 600), main.frame.height);
    try std.testing.expectEqual(@as(f32, 2), main.scale_factor);
    const settings = parseWindow(writer.buffered(), "settings").?;
    try std.testing.expect(!settings.open);
    try std.testing.expectEqual(@as(u64, 2), settings.id);
    var parsed: [4]platform.WindowState = undefined;
    const windows = parseWindows(writer.buffered(), &parsed);
    try std.testing.expectEqual(@as(usize, 2), windows.len);
    try std.testing.expectEqualStrings("settings", windows[1].label);
    try std.testing.expectEqual(@as(u64, 1), windows[0].id);
    try std.testing.expectEqual(@as(u64, 2), windows[1].id);
}

test "window state escapes and parses quoted titles and labels" {
    const special_label = "tools\\\"panel";
    const special_title = "Title with \"quotes\", slash \\, newline\n, tab\t, and brace }";

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeWindows(&.{
        .{ .label = "main", .title = "Main", .frame = geometry.RectF.init(10, 20, 800, 600) },
        .{ .label = special_label, .title = special_title, .frame = geometry.RectF.init(30, 40, 500, 400), .open = false },
    }, &writer);

    const bytes = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\\\"quotes\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\\n") != null);

    var parsed: [4]platform.WindowState = undefined;
    var storage: [1024]u8 = undefined;
    const windows = parseWindowsInto(bytes, &parsed, &storage);
    try std.testing.expectEqual(@as(usize, 2), windows.len);
    try std.testing.expectEqualStrings(special_label, windows[1].label);
    try std.testing.expectEqualStrings(special_title, windows[1].title);

    var window_storage: [512]u8 = undefined;
    const restored = parseWindowInto(bytes, special_label, &window_storage).?;
    try std.testing.expectEqualStrings(special_title, restored.title);
    try std.testing.expect(!restored.open);
}

test "window state skips empty labels" {
    const bytes =
        \\.{
        \\  .windows = .{
        \\    .{ .id = 1, .label = "", .title = "Old", .x = 0, .y = 0, .width = 100, .height = 100 },
        \\    .{ .id = 2, .label = "main", .title = "Main", .x = 10, .y = 20, .width = 800, .height = 600 },
        \\  },
        \\}
    ;

    var parsed: [4]platform.WindowState = undefined;
    const windows = parseWindows(bytes, &parsed);
    try std.testing.expectEqual(@as(usize, 1), windows.len);
    try std.testing.expectEqualStrings("main", windows[0].label);
    try std.testing.expectEqual(@as(u64, 2), windows[0].id);

    try std.testing.expect(parseWindow(bytes, "") == null);
    const main = parseWindow(bytes, "main").?;
    try std.testing.expectEqual(@as(u64, 2), main.id);
}

test "window state skips malformed labels and preserves trailing records" {
    const bytes =
        \\.{
        \\  .windows = .{
        \\    .{ .id = 1, .label = "main", .title = "Main", .x = 10, .y = 20, .width = 800, .height = 600 },
        \\    .{ .id = 2, .label = "bad\q", .title = "Bad", .x = 0, .y = 0, .width = 100, .height = 100 },
        \\    .{ .id = 3, .label = "settings", .title = "Settings", .x = 30, .y = 40, .width = 500, .height = 400 },
        \\  },
        \\}
    ;

    var parsed: [4]platform.WindowState = undefined;
    var storage: [512]u8 = undefined;
    const windows = parseWindowsInto(bytes, &parsed, &storage);
    try std.testing.expectEqual(@as(usize, 2), windows.len);
    try std.testing.expectEqualStrings("main", windows[0].label);
    try std.testing.expectEqualStrings("settings", windows[1].label);
    try std.testing.expectEqual(@as(u64, 3), windows[1].id);

    var window_storage: [256]u8 = undefined;
    const settings = parseWindowInto(bytes, "settings", &window_storage).?;
    try std.testing.expectEqual(@as(u64, 3), settings.id);
}

test "window state serializes maximum window set within explicit limit" {
    var windows: [platform.max_windows]platform.WindowState = undefined;
    const long_title = "Settings window with a localized title long enough to exercise state serialization headroom";
    for (&windows, 0..) |*window, index| {
        window.* = .{
            .id = @intCast(index + 1),
            .label = if (index == 0) "main" else "secondary-window",
            .title = long_title,
            .frame = geometry.RectF.init(@floatFromInt(index), @floatFromInt(index + 1), 900, 700),
        };
    }

    var buffer: [max_serialized_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeWindows(&windows, &writer);
    try std.testing.expect(writer.buffered().len < max_serialized_bytes);

    var tiny: [64]u8 = undefined;
    var tiny_writer = std.Io.Writer.fixed(&tiny);
    try std.testing.expectError(error.WriteFailed, writeWindows(&windows, &tiny_writer));
}
