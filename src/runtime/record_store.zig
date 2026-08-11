//! SQLite-backed, engine-owned record store. The public effect layer passes
//! bounded wire payloads through `execute`; this module owns schema, SQL,
//! transactions, byte ordering, and page framing.

const std = @import("std");
const sqlite = @import("sqlite_engine.zig");

pub const max_key_bytes: usize = 512;
pub const max_value_bytes: usize = 1024 * 1024;
pub const max_batch_entries: usize = 64;
pub const max_batch_bytes: usize = 8 * 1024 * 1024;
pub const default_scan_limit: u32 = 100;
pub const max_scan_limit: u32 = 256;
/// Enough for one maximum-sized record plus its key and page framing. Larger
/// scans end at a record boundary and return that record's predecessor as the
/// next cursor; no key or value is ever cut.
pub const max_result_bytes: usize = max_value_bytes + (2 * max_key_bytes) + 32;
pub const schema_version: u32 = 1;

pub const Outcome = enum(u8) {
    ok,
    miss,
    io_failed,
    over_bound,
    bad_key,
    rejected,
    busy,
};

pub const Operation = enum(u8) { set, get, delete, scan, set_many };

pub const Execution = struct {
    outcome: Outcome,
    len: usize = 0,
};

pub const Binding = struct {
    context: *anyopaque,
    execute_fn: *const fn (context: *anyopaque, op: Operation, payload: []const u8, output: []u8) Execution,
    reserve_write_fn: *const fn (context: *anyopaque) u64,
    execute_write_fn: *const fn (context: *anyopaque, sequence: u64, op: Operation, payload: []const u8, output: []u8) Execution,
};

const schema =
    "CREATE TABLE IF NOT EXISTS kv (" ++
    "scope INTEGER NOT NULL DEFAULT 0," ++
    "k BLOB NOT NULL," ++
    "v BLOB NOT NULL," ++
    "PRIMARY KEY(scope,k)) WITHOUT ROWID;";

pub const Store = struct {
    allocator: std.mem.Allocator,
    write_db: sqlite.Connection,
    /// Durable stores keep reads on their own query-only connection so a
    /// cached get/scan never borrows the writer. In-memory tests intentionally
    /// leave this null: SQLite's `:memory:` database belongs to one connection.
    read_db: ?sqlite.Connection = null,
    path: [:0]u8,
    write_mutex: std.atomic.Mutex = .unlocked,
    read_mutex: std.atomic.Mutex = .unlocked,
    next_write_sequence: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    reserved_write_sequence: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn open(allocator: std.mem.Allocator, data_dir: []const u8) !Store {
        const path_plain = try std.fs.path.join(allocator, &.{ data_dir, "store.db" });
        defer allocator.free(path_plain);
        const path = try allocator.dupeZ(u8, path_plain);
        errdefer allocator.free(path);
        var write_db = try sqlite.Connection.open(path);
        errdefer write_db.close();
        try initialize(&write_db, true);
        var read_db = try sqlite.Connection.open(path);
        errdefer read_db.close();
        try read_db.exec("PRAGMA busy_timeout=250;");
        try read_db.exec("PRAGMA query_only=ON;");
        return .{ .allocator = allocator, .write_db = write_db, .read_db = read_db, .path = path };
    }

    pub fn openMemory(allocator: std.mem.Allocator) !Store {
        const path = try allocator.dupeZ(u8, ":memory:");
        errdefer allocator.free(path);
        var write_db = try sqlite.Connection.open(path);
        errdefer write_db.close();
        try initialize(&write_db, false);
        return .{ .allocator = allocator, .write_db = write_db, .path = path };
    }

    pub fn deinit(self: *Store) void {
        self.lockWrite();
        if (self.read_db) |*db| {
            self.lockRead();
            db.close();
            self.unlockRead();
        }
        self.write_db.close();
        self.unlockWrite();
        self.allocator.free(self.path);
    }

    pub fn binding(self: *Store) Binding {
        return .{
            .context = self,
            .execute_fn = executeBound,
            .reserve_write_fn = reserveWriteBound,
            .execute_write_fn = executeWriteBound,
        };
    }

    pub fn execute(self: *Store, op: Operation, payload: []const u8, output: []u8) Execution {
        // Reads stay on the issuing thread, but they may not pass a write
        // already reserved by an earlier command in the same walk. No later
        // write can be reserved while that walk is waiting here, so this
        // snapshot is the exact command-stream barrier the read owes.
        const write_barrier = self.reserved_write_sequence.load(.acquire);
        while (self.next_write_sequence.load(.acquire) < write_barrier) std.Thread.yield() catch {};
        return self.executeRaw(op, payload, output);
    }

    fn executeRaw(self: *Store, op: Operation, payload: []const u8, output: []u8) Execution {
        return switch (op) {
            .get => blk: {
                self.lockRead();
                defer self.unlockRead();
                break :blk self.executeGet(payload, output);
            },
            .scan => blk: {
                self.lockRead();
                defer self.unlockRead();
                break :blk self.executeScan(payload, output);
            },
            .set => blk: {
                self.lockWrite();
                defer self.unlockWrite();
                break :blk self.executeSet(payload);
            },
            .delete => blk: {
                self.lockWrite();
                defer self.unlockWrite();
                break :blk self.executeDelete(payload);
            },
            .set_many => blk: {
                self.lockWrite();
                defer self.unlockWrite();
                break :blk self.executeSetMany(payload);
            },
        };
    }

    fn executeBound(context: *anyopaque, op: Operation, payload: []const u8, output: []u8) Execution {
        const self: *Store = @ptrCast(@alignCast(context));
        return self.execute(op, payload, output);
    }

    /// Reserve a writer position on the loop thread. Workers may start in
    /// any OS scheduling order, but `executeWrite` admits them to SQLite in
    /// the exact order their effects were issued.
    pub fn reserveWrite(self: *Store) u64 {
        return self.reserved_write_sequence.fetchAdd(1, .monotonic);
    }

    pub fn executeWrite(self: *Store, sequence: u64, op: Operation, payload: []const u8, output: []u8) Execution {
        while (sequence != self.next_write_sequence.load(.acquire)) std.Thread.yield() catch {};
        defer _ = self.next_write_sequence.fetchAdd(1, .release);
        return self.executeRaw(op, payload, output);
    }

    fn reserveWriteBound(context: *anyopaque) u64 {
        const self: *Store = @ptrCast(@alignCast(context));
        return self.reserveWrite();
    }

    fn executeWriteBound(context: *anyopaque, sequence: u64, op: Operation, payload: []const u8, output: []u8) Execution {
        const self: *Store = @ptrCast(@alignCast(context));
        return self.executeWrite(sequence, op, payload, output);
    }

    fn executeSet(self: *Store, payload: []const u8) Execution {
        var cursor: Cursor = .{ .bytes = payload };
        const scope = cursor.int(u32) orelse return .{ .outcome = .rejected };
        const key = cursor.bytesField() orelse return .{ .outcome = .rejected };
        const value = cursor.bytesField() orelse return .{ .outcome = .rejected };
        if (!cursor.done()) return .{ .outcome = .rejected };
        if (!validKey(key)) return .{ .outcome = .bad_key };
        if (value.len > max_value_bytes) return .{ .outcome = .over_bound };

        var statement = self.write_db.prepare("INSERT INTO kv(scope,k,v) VALUES(?1,?2,?3) ON CONFLICT(scope,k) DO UPDATE SET v=excluded.v;") catch |err| return failure(err);
        defer statement.finalize();
        statement.bindInt(1, scope) catch |err| return failure(err);
        statement.bindBlob(2, key) catch |err| return failure(err);
        statement.bindBlob(3, value) catch |err| return failure(err);
        _ = statement.step() catch |err| return failure(err);
        return .{ .outcome = .ok };
    }

    fn executeGet(self: *Store, payload: []const u8, output: []u8) Execution {
        var cursor: Cursor = .{ .bytes = payload };
        const scope = cursor.int(u32) orelse return .{ .outcome = .rejected };
        const key = cursor.bytesField() orelse return .{ .outcome = .rejected };
        if (!cursor.done()) return .{ .outcome = .rejected };
        if (!validKey(key)) return .{ .outcome = .bad_key };

        var statement = self.readConnection().prepare("SELECT v FROM kv WHERE scope=?1 AND k=?2;") catch |err| return failure(err);
        defer statement.finalize();
        statement.bindInt(1, scope) catch |err| return failure(err);
        statement.bindBlob(2, key) catch |err| return failure(err);
        switch (statement.step() catch |err| return failure(err)) {
            .done => {
                if (output.len < 1) return .{ .outcome = .over_bound };
                output[0] = 0;
                return .{ .outcome = .miss, .len = 1 };
            },
            .row => {
                const value = statement.columnBlob(0);
                if (value.len > max_value_bytes or output.len < value.len + 1) return .{ .outcome = .over_bound };
                output[0] = 1;
                @memcpy(output[1 .. value.len + 1], value);
                return .{ .outcome = .ok, .len = value.len + 1 };
            },
        }
    }

    fn executeDelete(self: *Store, payload: []const u8) Execution {
        var cursor: Cursor = .{ .bytes = payload };
        const scope = cursor.int(u32) orelse return .{ .outcome = .rejected };
        const key = cursor.bytesField() orelse return .{ .outcome = .rejected };
        if (!cursor.done()) return .{ .outcome = .rejected };
        if (!validKey(key)) return .{ .outcome = .bad_key };
        var statement = self.write_db.prepare("DELETE FROM kv WHERE scope=?1 AND k=?2;") catch |err| return failure(err);
        defer statement.finalize();
        statement.bindInt(1, scope) catch |err| return failure(err);
        statement.bindBlob(2, key) catch |err| return failure(err);
        _ = statement.step() catch |err| return failure(err);
        return .{ .outcome = .ok };
    }

    fn executeScan(self: *Store, payload: []const u8, output: []u8) Execution {
        var cursor: Cursor = .{ .bytes = payload };
        const scope = cursor.int(u32) orelse return .{ .outcome = .rejected };
        const prefix = cursor.bytesField() orelse return .{ .outcome = .rejected };
        const requested_limit = cursor.int(u32) orelse return .{ .outcome = .rejected };
        const after = cursor.bytesField() orelse return .{ .outcome = .rejected };
        if (!cursor.done()) return .{ .outcome = .rejected };
        if (!validPrefix(prefix) or (after.len > 0 and !validKey(after))) return .{ .outcome = .bad_key };
        const limit = if (requested_limit == 0) default_scan_limit else requested_limit;
        if (limit > max_scan_limit) return .{ .outcome = .over_bound };
        if (output.len < 8) return .{ .outcome = .over_bound };

        var statement = self.readConnection().prepare(
            "SELECT k,v FROM kv WHERE scope=?1 " ++
                "AND (?2=X'' OR substr(k,1,length(?2))=?2) " ++
                "AND (?3=X'' OR k>?3) ORDER BY k LIMIT ?4;",
        ) catch |err| return failure(err);
        defer statement.finalize();
        statement.bindInt(1, scope) catch |err| return failure(err);
        statement.bindBlob(2, prefix) catch |err| return failure(err);
        statement.bindBlob(3, after) catch |err| return failure(err);
        statement.bindInt(4, @as(i64, limit) + 1) catch |err| return failure(err);

        var writer = PageWriter.init(output);
        writer.writeInt(u32, 0) catch return .{ .outcome = .over_bound };
        var count: u32 = 0;
        var last_key_buffer: [max_key_bytes]u8 = undefined;
        var last_key_len: usize = 0;
        var has_more = false;
        while (true) {
            switch (statement.step() catch |err| return failure(err)) {
                .done => break,
                .row => {
                    const key = statement.columnBlob(0);
                    const value = statement.columnBlob(1);
                    if (count >= limit) {
                        has_more = true;
                        break;
                    }
                    const needed = 4 + key.len + 4 + value.len + 4 + key.len;
                    if (writer.remaining() < needed) {
                        // The row is left whole for the next page. A first row
                        // always fits by max_result_bytes' definition.
                        if (count == 0) return .{ .outcome = .over_bound };
                        has_more = true;
                        break;
                    }
                    writer.writeBytes(key) catch unreachable;
                    writer.writeBytes(value) catch unreachable;
                    count += 1;
                    @memcpy(last_key_buffer[0..key.len], key);
                    last_key_len = key.len;
                },
            }
        }
        std.mem.writeInt(u32, output[0..4], count, .little);
        writer.writeBytes(if (has_more) last_key_buffer[0..last_key_len] else "") catch return .{ .outcome = .over_bound };
        return .{ .outcome = .ok, .len = writer.at };
    }

    fn executeSetMany(self: *Store, payload: []const u8) Execution {
        if (payload.len > max_batch_bytes) return .{ .outcome = .over_bound };
        var cursor: Cursor = .{ .bytes = payload };
        const scope = cursor.int(u32) orelse return .{ .outcome = .rejected };
        const count = cursor.int(u32) orelse return .{ .outcome = .rejected };
        if (count == 0 or count > max_batch_entries) return .{ .outcome = .over_bound };

        // Validate the complete envelope before opening a transaction. This
        // keeps malformed batches out of SQLite altogether.
        var validation = cursor;
        for (0..count) |_| {
            const key = validation.bytesField() orelse return .{ .outcome = .rejected };
            const value = validation.bytesField() orelse return .{ .outcome = .rejected };
            if (!validKey(key)) return .{ .outcome = .bad_key };
            if (value.len > max_value_bytes) return .{ .outcome = .over_bound };
        }
        if (!validation.done()) return .{ .outcome = .rejected };

        self.write_db.exec("BEGIN IMMEDIATE;") catch |err| return failure(err);
        var committed = false;
        defer if (!committed) self.write_db.exec("ROLLBACK;") catch {};
        var statement = self.write_db.prepare("INSERT INTO kv(scope,k,v) VALUES(?1,?2,?3) ON CONFLICT(scope,k) DO UPDATE SET v=excluded.v;") catch |err| return failure(err);
        defer statement.finalize();
        for (0..count) |_| {
            const key = cursor.bytesField().?;
            const value = cursor.bytesField().?;
            statement.bindInt(1, scope) catch |err| return failure(err);
            statement.bindBlob(2, key) catch |err| return failure(err);
            statement.bindBlob(3, value) catch |err| return failure(err);
            _ = statement.step() catch |err| return failure(err);
            statement.reset() catch |err| return failure(err);
        }
        std.debug.assert(cursor.done());
        self.write_db.exec("COMMIT;") catch |err| return failure(err);
        committed = true;
        return .{ .outcome = .ok };
    }

    fn readConnection(self: *Store) *sqlite.Connection {
        if (self.read_db) |*db| return db;
        return &self.write_db;
    }

    fn lockWrite(self: *Store) void {
        while (!self.write_mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlockWrite(self: *Store) void {
        self.write_mutex.unlock();
    }

    fn lockRead(self: *Store) void {
        // An in-memory store has no second connection, so its reads share the
        // writer mutex as well as the writer handle.
        const mutex = if (self.read_db != null) &self.read_mutex else &self.write_mutex;
        while (!mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlockRead(self: *Store) void {
        const mutex = if (self.read_db != null) &self.read_mutex else &self.write_mutex;
        mutex.unlock();
    }
};

fn initialize(db: *sqlite.Connection, durable: bool) !void {
    const version = blk: {
        var version_query = try db.prepare("PRAGMA user_version;");
        defer version_query.finalize();
        if (try version_query.step() != .row) return error.InvalidSchemaVersion;
        break :blk version_query.columnInt(0);
    };
    if (version < 0 or version > schema_version) return error.VersionUnknown;
    if (durable) {
        try db.exec("PRAGMA journal_mode=WAL;");
        try db.exec("PRAGMA synchronous=NORMAL;");
        try db.exec("PRAGMA busy_timeout=250;");
    }
    try db.exec(schema);
    if (version == 0) try db.exec("PRAGMA user_version=1;");
}

pub fn outcomeName(outcome: Outcome) []const u8 {
    return @tagName(outcome);
}

fn failure(err: sqlite.Error) Execution {
    return .{ .outcome = if (err == error.Busy) .busy else .io_failed };
}

pub fn validKey(key: []const u8) bool {
    return key.len > 0 and key.len <= max_key_bytes and std.unicode.utf8ValidateSlice(key);
}

pub fn validPrefix(prefix: []const u8) bool {
    return prefix.len <= max_key_bytes and std.unicode.utf8ValidateSlice(prefix);
}

const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,

    fn int(self: *Cursor, comptime T: type) ?T {
        if (self.at > self.bytes.len or self.bytes.len - self.at < @sizeOf(T)) return null;
        const value = std.mem.readInt(T, self.bytes[self.at..][0..@sizeOf(T)], .little);
        self.at += @sizeOf(T);
        return value;
    }

    fn bytesField(self: *Cursor) ?[]const u8 {
        const len: usize = self.int(u32) orelse return null;
        if (len > self.bytes.len - self.at) return null;
        const value = self.bytes[self.at..][0..len];
        self.at += len;
        return value;
    }

    fn done(self: *const Cursor) bool {
        return self.at == self.bytes.len;
    }
};

const PageWriter = struct {
    buffer: []u8,
    at: usize = 0,

    fn init(buffer: []u8) PageWriter {
        return .{ .buffer = buffer };
    }

    fn remaining(self: *const PageWriter) usize {
        return self.buffer.len - self.at;
    }

    fn writeInt(self: *PageWriter, comptime T: type, value: T) error{NoSpace}!void {
        if (self.remaining() < @sizeOf(T)) return error.NoSpace;
        std.mem.writeInt(T, self.buffer[self.at..][0..@sizeOf(T)], value, .little);
        self.at += @sizeOf(T);
    }

    fn writeBytes(self: *PageWriter, bytes: []const u8) error{NoSpace}!void {
        if (bytes.len > std.math.maxInt(u32) or self.remaining() < 4 + bytes.len) return error.NoSpace;
        try self.writeInt(u32, @intCast(bytes.len));
        @memcpy(self.buffer[self.at..][0..bytes.len], bytes);
        self.at += bytes.len;
    }
};

fn request(allocator: std.mem.Allocator, scope: u32, fields: []const []const u8) ![]u8 {
    var len: usize = 4;
    for (fields) |field| len += 4 + field.len;
    const bytes = try allocator.alloc(u8, len);
    std.mem.writeInt(u32, bytes[0..4], scope, .little);
    var writer = PageWriter{ .buffer = bytes, .at = 4 };
    for (fields) |field| try writer.writeBytes(field);
    return bytes;
}

fn scanRequest(allocator: std.mem.Allocator, scope: u32, prefix: []const u8, limit: u32, after: []const u8) ![]u8 {
    const bytes = try allocator.alloc(u8, 16 + prefix.len + after.len);
    var writer = PageWriter.init(bytes);
    try writer.writeInt(u32, scope);
    try writer.writeBytes(prefix);
    try writer.writeInt(u32, limit);
    try writer.writeBytes(after);
    return bytes;
}

const TestEntry = struct { key: []const u8, value: []const u8 };

fn setManyRequest(allocator: std.mem.Allocator, scope: u32, entries: []const TestEntry) ![]u8 {
    var len: usize = 8;
    for (entries) |entry| len += 8 + entry.key.len + entry.value.len;
    const bytes = try allocator.alloc(u8, len);
    var writer = PageWriter.init(bytes);
    try writer.writeInt(u32, scope);
    try writer.writeInt(u32, @intCast(entries.len));
    for (entries) |entry| {
        try writer.writeBytes(entry.key);
        try writer.writeBytes(entry.value);
    }
    return bytes;
}

test "durable stores read through a dedicated WAL connection" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/record-store", .{tmp.sub_path[0..]});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, path);
    var store = try Store.open(allocator, path);
    defer store.deinit();
    try std.testing.expect(store.read_db != null);

    var output: [max_result_bytes]u8 = undefined;
    const set_payload = try request(allocator, 0, &.{ "durable/key", "value" });
    defer allocator.free(set_payload);
    try std.testing.expectEqual(Outcome.ok, store.execute(.set, set_payload, &output).outcome);
    const get_payload = try request(allocator, 0, &.{"durable/key"});
    defer allocator.free(get_payload);
    const found = store.execute(.get, get_payload, &output);
    try std.testing.expectEqual(Outcome.ok, found.outcome);
    try std.testing.expectEqualSlices(u8, "value", output[1..found.len]);
}

test "record store CRUD distinguishes empty values from misses" {
    const allocator = std.testing.allocator;
    var store = try Store.openMemory(allocator);
    defer store.deinit();
    var output: [max_result_bytes]u8 = undefined;

    const set_payload = try request(allocator, 0, &.{ "doc/a", "" });
    defer allocator.free(set_payload);
    try std.testing.expectEqual(Outcome.ok, store.execute(.set, set_payload, &output).outcome);

    const get_payload = try request(allocator, 0, &.{"doc/a"});
    defer allocator.free(get_payload);
    const found = store.execute(.get, get_payload, &output);
    try std.testing.expectEqual(Outcome.ok, found.outcome);
    try std.testing.expectEqualSlices(u8, &.{1}, output[0..found.len]);

    const missing_payload = try request(allocator, 0, &.{"doc/missing"});
    defer allocator.free(missing_payload);
    const missing = store.execute(.get, missing_payload, &output);
    try std.testing.expectEqual(Outcome.miss, missing.outcome);
    try std.testing.expectEqualSlices(u8, &.{0}, output[0..missing.len]);

    try std.testing.expectEqual(Outcome.ok, store.execute(.delete, get_payload, &output).outcome);
    try std.testing.expectEqual(Outcome.miss, store.execute(.get, get_payload, &output).outcome);
}

test "record store scan is byte ordered and paginated" {
    const allocator = std.testing.allocator;
    var store = try Store.openMemory(allocator);
    defer store.deinit();
    var output: [max_result_bytes]u8 = undefined;
    const keys = [_][]const u8{ "chat/1", "chat/2", "chat/3", "other/1" };
    for (&keys) |key| {
        const payload = try request(allocator, 0, &.{ key, key });
        defer allocator.free(payload);
        try std.testing.expectEqual(Outcome.ok, store.execute(.set, payload, &output).outcome);
    }

    const first_request = try scanRequest(allocator, 0, "chat/", 2, "");
    defer allocator.free(first_request);
    const first_page = store.execute(.scan, first_request, &output);
    try std.testing.expectEqual(Outcome.ok, first_page.outcome);
    var first = Cursor{ .bytes = output[0..first_page.len] };
    try std.testing.expectEqual(@as(u32, 2), first.int(u32).?);
    try std.testing.expectEqualStrings("chat/1", first.bytesField().?);
    try std.testing.expectEqualStrings("chat/1", first.bytesField().?);
    try std.testing.expectEqualStrings("chat/2", first.bytesField().?);
    try std.testing.expectEqualStrings("chat/2", first.bytesField().?);
    const next = first.bytesField().?;
    var next_copy: [max_key_bytes]u8 = undefined;
    @memcpy(next_copy[0..next.len], next);
    try std.testing.expectEqualStrings("chat/2", next);
    try std.testing.expect(first.done());

    const second_request = try scanRequest(allocator, 0, "chat/", 2, next_copy[0..next.len]);
    defer allocator.free(second_request);
    const second_page = store.execute(.scan, second_request, &output);
    try std.testing.expectEqual(Outcome.ok, second_page.outcome);
    var second = Cursor{ .bytes = output[0..second_page.len] };
    try std.testing.expectEqual(@as(u32, 1), second.int(u32).?);
    try std.testing.expectEqualStrings("chat/3", second.bytesField().?);
    try std.testing.expectEqualStrings("chat/3", second.bytesField().?);
    try std.testing.expectEqual(@as(usize, 0), second.bytesField().?.len);
    try std.testing.expect(second.done());
}

test "record store setMany rolls back the whole batch on a bad key" {
    const allocator = std.testing.allocator;
    var store = try Store.openMemory(allocator);
    defer store.deinit();
    var output: [max_result_bytes]u8 = undefined;
    var bytes: [4 + 4 + 4 + 2 + 4 + 1 + 4 + 0 + 4 + 1]u8 = undefined;
    var writer = PageWriter.init(&bytes);
    try writer.writeInt(u32, 0);
    try writer.writeInt(u32, 2);
    try writer.writeBytes("ok");
    try writer.writeBytes("1");
    try writer.writeBytes("");
    try writer.writeBytes("2");
    try std.testing.expectEqual(Outcome.bad_key, store.execute(.set_many, &bytes, &output).outcome);
    const get_payload = try request(allocator, 0, &.{"ok"});
    defer allocator.free(get_payload);
    try std.testing.expectEqual(Outcome.miss, store.execute(.get, get_payload, &output).outcome);
}

test "record store setMany rolls back writes when SQLite rejects a later row" {
    const allocator = std.testing.allocator;
    var store = try Store.openMemory(allocator);
    defer store.deinit();
    try store.write_db.exec(
        "CREATE TRIGGER reject_second BEFORE INSERT ON kv " ++
            "WHEN new.k=X'626164' BEGIN SELECT RAISE(ABORT,'fixture'); END;",
    );
    const entries = [_]TestEntry{
        .{ .key = "kept-only-on-commit", .value = "one" },
        .{ .key = "bad", .value = "two" },
    };
    const payload = try setManyRequest(allocator, 0, &entries);
    defer allocator.free(payload);
    var output: [max_result_bytes]u8 = undefined;
    try std.testing.expectEqual(Outcome.io_failed, store.execute(.set_many, payload, &output).outcome);

    const get_payload = try request(allocator, 0, &.{"kept-only-on-commit"});
    defer allocator.free(get_payload);
    try std.testing.expectEqual(Outcome.miss, store.execute(.get, get_payload, &output).outcome);
}

test "record store enforces exact key value scan and batch bounds" {
    const allocator = std.testing.allocator;
    var store = try Store.openMemory(allocator);
    defer store.deinit();
    const output = try allocator.alloc(u8, max_result_bytes);
    defer allocator.free(output);

    const max_key = try allocator.alloc(u8, max_key_bytes);
    defer allocator.free(max_key);
    @memset(max_key, 'k');
    const max_value = try allocator.alloc(u8, max_value_bytes);
    defer allocator.free(max_value);
    @memset(max_value, 0xa5);
    const exact = try request(allocator, 0, &.{ max_key, max_value });
    defer allocator.free(exact);
    try std.testing.expectEqual(Outcome.ok, store.execute(.set, exact, output).outcome);

    const exact_get = try request(allocator, 0, &.{max_key});
    defer allocator.free(exact_get);
    const found = store.execute(.get, exact_get, output);
    try std.testing.expectEqual(Outcome.ok, found.outcome);
    try std.testing.expectEqual(max_value_bytes + 1, found.len);
    try std.testing.expectEqualSlices(u8, max_value, output[1..found.len]);

    const long_key = try allocator.alloc(u8, max_key_bytes + 1);
    defer allocator.free(long_key);
    @memset(long_key, 'x');
    const long_key_request = try request(allocator, 0, &.{long_key});
    defer allocator.free(long_key_request);
    try std.testing.expectEqual(Outcome.bad_key, store.execute(.get, long_key_request, output).outcome);
    const empty_key_request = try request(allocator, 0, &.{""});
    defer allocator.free(empty_key_request);
    try std.testing.expectEqual(Outcome.bad_key, store.execute(.get, empty_key_request, output).outcome);
    const invalid_utf8_request = try request(allocator, 0, &.{&.{0xff}});
    defer allocator.free(invalid_utf8_request);
    try std.testing.expectEqual(Outcome.bad_key, store.execute(.get, invalid_utf8_request, output).outcome);

    const long_value = try allocator.alloc(u8, max_value_bytes + 1);
    defer allocator.free(long_value);
    @memset(long_value, 0x5a);
    const long_value_request = try request(allocator, 0, &.{ "value/too-large", long_value });
    defer allocator.free(long_value_request);
    try std.testing.expectEqual(Outcome.over_bound, store.execute(.set, long_value_request, output).outcome);

    const long_prefix_request = try scanRequest(allocator, 0, long_key, 1, "");
    defer allocator.free(long_prefix_request);
    try std.testing.expectEqual(Outcome.bad_key, store.execute(.scan, long_prefix_request, output).outcome);
    const long_limit_request = try scanRequest(allocator, 0, "", max_scan_limit + 1, "");
    defer allocator.free(long_limit_request);
    try std.testing.expectEqual(Outcome.over_bound, store.execute(.scan, long_limit_request, output).outcome);

    var too_many_header: [8]u8 = undefined;
    std.mem.writeInt(u32, too_many_header[0..4], 0, .little);
    std.mem.writeInt(u32, too_many_header[4..8], max_batch_entries + 1, .little);
    try std.testing.expectEqual(Outcome.over_bound, store.execute(.set_many, &too_many_header, output).outcome);
    const oversized_batch = try allocator.alloc(u8, max_batch_bytes + 1);
    defer allocator.free(oversized_batch);
    @memset(oversized_batch, 0);
    try std.testing.expectEqual(Outcome.over_bound, store.execute(.set_many, oversized_batch, output).outcome);
}

test "record store scopes remain isolated on the extensible wire" {
    const allocator = std.testing.allocator;
    var store = try Store.openMemory(allocator);
    defer store.deinit();
    var output: [max_result_bytes]u8 = undefined;
    const scoped_set = try request(allocator, 7, &.{ "shared/key", "scoped" });
    defer allocator.free(scoped_set);
    try std.testing.expectEqual(Outcome.ok, store.execute(.set, scoped_set, &output).outcome);
    const default_get = try request(allocator, 0, &.{"shared/key"});
    defer allocator.free(default_get);
    try std.testing.expectEqual(Outcome.miss, store.execute(.get, default_get, &output).outcome);
    const scoped_get = try request(allocator, 7, &.{"shared/key"});
    defer allocator.free(scoped_get);
    const found = store.execute(.get, scoped_get, &output);
    try std.testing.expectEqual(Outcome.ok, found.outcome);
    try std.testing.expectEqualStrings("scoped", output[1..found.len]);
}

test "record store reports busy and io failures through the closed outcome enum" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/record-store-failures", .{tmp.sub_path[0..]});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, path);
    var locking = try Store.open(allocator, path);
    defer locking.deinit();
    var blocked = try Store.open(allocator, path);
    defer blocked.deinit();
    try locking.write_db.exec("BEGIN IMMEDIATE;");
    defer locking.write_db.exec("ROLLBACK;") catch {};
    const set_payload = try request(allocator, 0, &.{ "locked", "value" });
    defer allocator.free(set_payload);
    var output: [max_result_bytes]u8 = undefined;
    try std.testing.expectEqual(Outcome.busy, blocked.execute(.set, set_payload, &output).outcome);

    var broken = try Store.openMemory(allocator);
    defer broken.deinit();
    try broken.write_db.exec("DROP TABLE kv;");
    const get_payload = try request(allocator, 0, &.{"missing-table"});
    defer allocator.free(get_payload);
    try std.testing.expectEqual(Outcome.io_failed, broken.execute(.get, get_payload, &output).outcome);
}

test "record store refuses schema versions newer than the engine" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/record-store-version", .{tmp.sub_path[0..]});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    const path_plain = try std.fs.path.join(allocator, &.{ dir, "store.db" });
    defer allocator.free(path_plain);
    const path = try allocator.dupeZ(u8, path_plain);
    defer allocator.free(path);
    var db = try sqlite.Connection.open(path);
    try db.exec("PRAGMA user_version=2;");
    db.close();
    try std.testing.expectError(error.VersionUnknown, Store.open(allocator, dir));
}

test "record store workers commit in reserved issue order" {
    const allocator = std.testing.allocator;
    var store = try Store.openMemory(allocator);
    defer store.deinit();
    const first = try request(allocator, 0, &.{ "ordered/key", "first" });
    defer allocator.free(first);
    const second = try request(allocator, 0, &.{ "ordered/key", "second" });
    defer allocator.free(second);

    const first_sequence = store.reserveWrite();
    const second_sequence = store.reserveWrite();
    var second_output: [32]u8 = undefined;
    const Worker = struct {
        fn run(target: *Store, sequence: u64, payload: []const u8, output: []u8) void {
            const result = target.executeWrite(sequence, .set, payload, output);
            std.debug.assert(result.outcome == .ok);
        }
    };
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{ &store, second_sequence, second, &second_output });
    var first_output: [32]u8 = undefined;
    try std.testing.expectEqual(Outcome.ok, store.executeWrite(first_sequence, .set, first, &first_output).outcome);
    second_thread.join();

    const get_payload = try request(allocator, 0, &.{"ordered/key"});
    defer allocator.free(get_payload);
    var output: [max_result_bytes]u8 = undefined;
    const found = store.execute(.get, get_payload, &output);
    try std.testing.expectEqual(Outcome.ok, found.outcome);
    try std.testing.expectEqualSlices(u8, "second", output[1..found.len]);
}

test "synchronous reads wait for earlier reserved writes" {
    const allocator = std.testing.allocator;
    var store = try Store.openMemory(allocator);
    defer store.deinit();
    const set_payload = try request(allocator, 0, &.{ "ordered/read", "visible" });
    defer allocator.free(set_payload);
    const get_payload = try request(allocator, 0, &.{"ordered/read"});
    defer allocator.free(get_payload);

    const sequence = store.reserveWrite();
    var write_output: [32]u8 = undefined;
    const Worker = struct {
        fn run(target: *Store, write_sequence: u64, payload: []const u8, output: []u8) void {
            // Make it plausible for the loop-thread read to reach its barrier
            // before this worker enters SQLite.
            std.Thread.yield() catch {};
            const result = target.executeWrite(write_sequence, .set, payload, output);
            std.debug.assert(result.outcome == .ok);
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &store, sequence, set_payload, &write_output });

    var output: [max_result_bytes]u8 = undefined;
    const found = store.execute(.get, get_payload, &output);
    thread.join();
    try std.testing.expectEqual(Outcome.ok, found.outcome);
    try std.testing.expectEqualSlices(u8, "visible", output[1..found.len]);
}
