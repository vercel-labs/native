//! `native db`: append-only migration authoring and development database
//! inspection/reset. Paths are always resolved from app identity through
//! app_dirs; the CLI never accepts an arbitrary database path.

const std = @import("std");
const app_dirs = @import("app_dirs");
const debug = @import("debug");
const manifest_tool = @import("manifest.zig");
const sqlite = @import("sqlite_engine");

pub const Error = error{ InvalidArguments, InvalidMigrationName, MigrationLimitReached, ResetNeedsConfirmation };

pub fn run(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, args: []const []const u8) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        usage();
        return;
    }
    const verb = args[0];
    if (std.mem.eql(u8, verb, "new-migration")) {
        if (args.len != 2) return Error.InvalidArguments;
        try newMigration(allocator, io, args[1]);
    } else if (std.mem.eql(u8, verb, "status")) {
        if (args.len != 1) return Error.InvalidArguments;
        try status(allocator, io, env);
    } else if (std.mem.eql(u8, verb, "reset")) {
        if (args.len != 2 or !std.mem.eql(u8, args[1], "--yes")) return Error.ResetNeedsConfirmation;
        try reset(allocator, io, env);
    } else return Error.InvalidArguments;
}

fn usage() void {
    std.debug.print(
        \\usage: native db <command>
        \\
        \\commands:
        \\  new-migration <name>   append src/schema/NNNN_name.sql
        \\  status                 show source and installed schema versions
        \\  reset --yes            delete this app's engine-owned development app.db
        \\
    , .{});
}

fn newMigration(allocator: std.mem.Allocator, io: std.Io, authored_name: []const u8) !void {
    if (authored_name.len == 0 or authored_name.len > 64) return Error.InvalidMigrationName;
    const safe = try allocator.alloc(u8, authored_name.len);
    defer allocator.free(safe);
    var previous_separator = false;
    for (authored_name, 0..) |char, index| {
        const lowered = std.ascii.toLower(char);
        if ((lowered >= 'a' and lowered <= 'z') or (lowered >= '0' and lowered <= '9')) {
            safe[index] = lowered;
            previous_separator = false;
        } else if ((char == '-' or char == '_' or char == ' ') and index > 0 and !previous_separator) {
            safe[index] = '_';
            previous_separator = true;
        } else return Error.InvalidMigrationName;
    }
    if (safe[0] == '_' or safe[safe.len - 1] == '_') return Error.InvalidMigrationName;
    try std.Io.Dir.cwd().createDirPath(io, "src/schema");
    var dir = try std.Io.Dir.cwd().openDir(io, "src/schema", .{ .iterate = true });
    defer dir.close(io);
    var highest: u32 = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or entry.name.len < 9 or !std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const version = std.fmt.parseUnsigned(u32, entry.name[0..4], 10) catch continue;
        if (entry.name[4] != '_') continue;
        highest = @max(highest, version);
    }
    if (highest >= 9999) return Error.MigrationLimitReached;
    const version = highest + 1;
    const file_name = try std.fmt.allocPrint(allocator, "src/schema/{d:0>4}_{s}.sql", .{ version, safe });
    defer allocator.free(file_name);
    var file = try std.Io.Dir.cwd().createFile(io, file_name, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(
        io,
        "-- Append-only SQLite migration. Use STRICT tables so generated types stay honest.\n" ++
            "-- This version may never be edited after it is shipped.\n\n",
    );
    std.debug.print("created {s}\n", .{file_name});
}

fn status(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !void {
    const target = try migrationSourceVersion(io);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const db_path = try appDbPath(allocator, io, env, &path_buffer);
    const installed = readUserVersion(allocator, io, db_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (installed) |version| {
        const relation = if (version == target) "current" else if (version < target) "pending migrations" else "newer than this source (runtime will refuse it)";
        std.debug.print("source schema: {d}\ninstalled schema: {d} ({s})\ndatabase: {s}\n", .{ target, version, relation, db_path });
    } else {
        std.debug.print("source schema: {d}\ninstalled schema: none (created on first launch)\ndatabase: {s}\n", .{ target, db_path });
    }
}

fn reset(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const db_path = try appDbPath(allocator, io, env, &path_buffer);
    for ([_][]const u8{ "", "-wal", "-shm" }) |suffix| {
        const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ db_path, suffix });
        defer allocator.free(path);
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    std.debug.print("reset relational database {s} (the next development launch reapplies every migration)\n", .{db_path});
}

fn migrationSourceVersion(io: std.Io) !u32 {
    var dir = std.Io.Dir.cwd().openDir(io, "src/schema", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);
    var count: u32 = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .file and entry.name.len >= 9 and entry.name[4] == '_' and std.mem.endsWith(u8, entry.name, ".sql")) count += 1;
    }
    return count;
}

fn appDbPath(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, buffer: []u8) ![]const u8 {
    const metadata = try manifest_tool.readMetadata(allocator, io, "app.zon");
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try app_dirs.resolveOne(
        .{ .name = metadata.id },
        app_dirs.currentPlatform(),
        debug.envFromMap(env),
        .data,
        &dir_buffer,
    );
    return std.fmt.bufPrint(buffer, "{s}/app.db", .{data_dir});
}

/// Read through SQLite rather than the file header: WAL may carry a newer
/// user_version than byte 60 in the main database until checkpoint.
fn readUserVersion(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !u32 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    file.close(io);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var connection = try sqlite.Connection.open(path_z);
    defer connection.close();
    var statement = try connection.prepareOne("PRAGMA user_version;");
    defer statement.finalize();
    if ((try statement.step()) != .row) return error.InvalidDatabaseHeader;
    const version = statement.columnInt(0);
    if (version < 0 or version > 9999) return error.InvalidDatabaseHeader;
    return @intCast(version);
}

test "migration author names are bounded and normalized" {
    try std.testing.expectError(Error.InvalidMigrationName, newMigration(std.testing.allocator, std.testing.io, "../escape"));
}
