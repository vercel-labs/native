//! Engine-owned relational SQLite database. This module is intentionally a
//! synchronous host binding: `Effects.dbQuery` calls it while walking inert
//! commands, copies bounded pages into the loop-side result queue, and only
//! then lets the resulting Msg values reach `update`.

const std = @import("std");
const sqlite = @import("sqlite_engine.zig");

pub const max_sql_bytes: usize = 64 * 1024;
pub const max_parameters: usize = 64;
pub const max_exec_statements: usize = 64;
pub const max_parameter_bytes: usize = 1024 * 1024;
pub const max_exec_parameter_bytes: usize = 8 * 1024 * 1024;
pub const default_page_rows: usize = 256;
pub const max_page_bytes: usize = 256 * 1024;
pub const max_result_rows: usize = 8 * 1024;
pub const max_result_bytes: usize = 8 * 1024 * 1024;
pub const max_migrations: usize = 9999;
pub const max_migration_bytes: usize = 1024 * 1024;
pub const max_changed_tables: usize = 64;
pub const max_table_name_bytes: usize = 255;

pub const Migration = struct {
    version: u32,
    name: []const u8,
    sql: []const u8,
};

pub const OpenOutcome = enum(u8) {
    ok,
    migrate_failed,
    version_unknown,
};

pub const OpenResult = struct {
    database: ?Database = null,
    outcome: OpenOutcome,
    version: u32 = 0,
};

pub const ChangedTable = struct {
    len: u8 = 0,
    bytes: [max_table_name_bytes]u8 = undefined,

    pub fn name(self: *const ChangedTable) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const ChangeBatch = struct {
    revision: u64,
    tables: []const ChangedTable,
    /// The transaction touched more distinct tables than the bounded name
    /// set can retain. Consumers must conservatively invalidate every live
    /// query; overflow may cost work, but it can never leave subscribed data
    /// stale.
    all_tables: bool = false,
};

/// Stable tagged-value dialect shared by the Zig effect surface and the TS
/// wire decoder. Booleans cross the TS wire as integer 0/1 before reaching
/// this layer.
pub const Value = union(enum(u8)) {
    null_value,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

pub const Statement = struct {
    sql: []const u8,
    params: []const Value = &.{},
};

pub const Outcome = enum(u8) {
    ok,
    constraint,
    busy,
    io_failed,
    corrupt,
    misuse,
    rejected,
    cancelled,
};

pub const PageFn = *const fn (context: *anyopaque, bytes: []const u8) void;

pub const Binding = struct {
    context: *anyopaque,
    query_fn: *const fn (
        context: *anyopaque,
        sql: []const u8,
        params: []const Value,
        page_context: *anyopaque,
        page_fn: PageFn,
    ) Outcome,
    exec_fn: *const fn (context: *anyopaque, statements: []const Statement) Outcome,
    changes_fn: *const fn (context: *anyopaque, after_revision: u64) ChangeBatch,
};

/// One private app database. The durable form keeps a query-only reader next
/// to the WAL writer; `:memory:` tests use the writer for both roles because
/// an in-memory SQLite database belongs to one connection.
pub const Database = struct {
    allocator: std.mem.Allocator,
    write_db: sqlite.Connection,
    read_db: ?sqlite.Connection = null,
    path: [:0]u8,
    write_mutex: std.atomic.Mutex = .unlocked,
    read_mutex: std.atomic.Mutex = .unlocked,
    revision: u64 = 0,
    changed_tables: [max_changed_tables]ChangedTable = @splat(.{}),
    changed_table_count: usize = 0,
    changed_all_tables: bool = false,
    transaction_tables: [max_changed_tables]ChangedTable = @splat(.{}),
    transaction_table_count: usize = 0,
    transaction_all_tables: bool = false,

    pub fn open(allocator: std.mem.Allocator, data_dir: []const u8) !Database {
        const path_plain = try std.fs.path.join(allocator, &.{ data_dir, "app.db" });
        defer allocator.free(path_plain);
        const path = try allocator.dupeZ(u8, path_plain);
        errdefer allocator.free(path);

        var write_db = try sqlite.Connection.open(path);
        errdefer write_db.close();
        try initializeWriter(&write_db, true);
        try write_db.installRelationalAuthorizer();

        var read_db = try sqlite.Connection.open(path);
        errdefer read_db.close();
        try read_db.exec("PRAGMA busy_timeout=250;");
        try read_db.exec("PRAGMA foreign_keys=ON;");
        try read_db.exec("PRAGMA query_only=ON;");
        try read_db.installRelationalAuthorizer();
        return .{ .allocator = allocator, .write_db = write_db, .read_db = read_db, .path = path };
    }

    pub fn openMemory(allocator: std.mem.Allocator) !Database {
        const path = try allocator.dupeZ(u8, ":memory:");
        errdefer allocator.free(path);
        var write_db = try sqlite.Connection.open(path);
        errdefer write_db.close();
        try initializeWriter(&write_db, false);
        try write_db.installRelationalAuthorizer();
        return .{ .allocator = allocator, .write_db = write_db, .path = path };
    }

    /// Open the durable database and apply every pending append-only
    /// migration in one transaction before the app installs. A newer file is
    /// never opened by an older binary.
    pub fn openMigrated(allocator: std.mem.Allocator, data_dir: []const u8, migrations: []const Migration) !OpenResult {
        var database = try Database.open(allocator, data_dir);
        const result = database.applyMigrations(migrations);
        if (result.outcome != .ok) {
            database.deinit();
            return result;
        }
        return .{ .database = database, .outcome = .ok, .version = result.version };
    }

    pub fn openMemoryMigrated(allocator: std.mem.Allocator, migrations: []const Migration) !OpenResult {
        var database = try Database.openMemory(allocator);
        const result = database.applyMigrations(migrations);
        if (result.outcome != .ok) {
            database.deinit();
            return result;
        }
        return .{ .database = database, .outcome = .ok, .version = result.version };
    }

    pub fn deinit(self: *Database) void {
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

    pub fn binding(self: *Database) Binding {
        return .{ .context = self, .query_fn = queryBound, .exec_fn = execBound, .changes_fn = changesBound };
    }

    pub fn schemaVersion(self: *Database) sqlite.Error!u32 {
        self.lockWrite();
        defer self.unlockWrite();
        return self.schemaVersionLocked();
    }

    pub fn applyMigrations(self: *Database, migrations: []const Migration) OpenResult {
        if (!validMigrations(migrations)) return .{ .outcome = .migrate_failed };
        self.lockWrite();
        defer self.unlockWrite();
        const current = self.schemaVersionLocked() catch return .{ .outcome = .migrate_failed };
        const target: u32 = if (migrations.len == 0) 0 else migrations[migrations.len - 1].version;
        if (current > target) return .{ .outcome = .version_unknown, .version = current };
        if (current == target) return .{ .outcome = .ok, .version = current };

        self.write_db.setRelationalAuthorizer(false) catch return .{ .outcome = .migrate_failed, .version = current };
        defer self.write_db.setRelationalAuthorizer(true) catch {};
        self.write_db.exec("BEGIN IMMEDIATE;") catch return .{ .outcome = .migrate_failed, .version = current };
        var committed = false;
        defer if (!committed) self.write_db.exec("ROLLBACK;") catch {};
        self.write_db.installRelationalMigrationAuthorizer() catch return .{ .outcome = .migrate_failed, .version = current };
        defer self.write_db.setRelationalAuthorizer(false) catch {};
        for (migrations) |migration| {
            if (migration.version <= current) continue;
            const sql_z = self.allocator.dupeZ(u8, migration.sql) catch return .{ .outcome = .migrate_failed, .version = current };
            defer self.allocator.free(sql_z);
            self.write_db.exec(sql_z) catch return .{ .outcome = .migrate_failed, .version = current };
        }
        self.write_db.setRelationalAuthorizer(false) catch return .{ .outcome = .migrate_failed, .version = current };
        var version_sql_buf: [64]u8 = undefined;
        const version_sql = std.fmt.bufPrintZ(&version_sql_buf, "PRAGMA user_version={d};", .{target}) catch
            return .{ .outcome = .migrate_failed, .version = current };
        self.write_db.exec(version_sql) catch return .{ .outcome = .migrate_failed, .version = current };
        self.write_db.exec("COMMIT;") catch return .{ .outcome = .migrate_failed, .version = current };
        committed = true;
        self.transaction_table_count = 0;
        self.transaction_all_tables = false;
        return .{ .outcome = .ok, .version = target };
    }

    fn schemaVersionLocked(self: *Database) sqlite.Error!u32 {
        self.write_db.setRelationalAuthorizer(false) catch return error.Misuse;
        defer self.write_db.setRelationalAuthorizer(true) catch {};
        var statement = try self.write_db.prepareOne("PRAGMA user_version;");
        defer statement.finalize();
        if ((try statement.step()) != .row) return error.StepFailed;
        const value = statement.columnInt(0);
        if (value < 0 or value > max_migrations) return error.Corrupt;
        return @intCast(value);
    }

    pub fn query(self: *Database, sql_text: []const u8, params: []const Value, page_context: *anyopaque, page_fn: PageFn) Outcome {
        if (!validSql(sql_text) or !validParameters(params, max_parameter_bytes)) return .rejected;
        const sql_z = self.allocator.dupeZ(u8, sql_text) catch return .io_failed;
        defer self.allocator.free(sql_z);

        self.lockRead();
        defer self.unlockRead();
        var statement = self.readConnection().prepareOne(sql_z) catch |err| return failure(err);
        defer statement.finalize();
        if (!statement.readOnly() or statement.parameterCount() != params.len) return .misuse;
        bindAll(&statement, params) catch |err| return failure(err);

        const column_count = statement.columnCount();
        if (column_count > std.math.maxInt(u16)) return .misuse;
        var page_buffer: [max_page_bytes]u8 = undefined;
        var row_buffer: [max_page_bytes]u8 = undefined;
        var page = PageWriter.init(&page_buffer);
        writeHeader(&page, &statement, column_count) catch return .misuse;
        var row_count: u32 = 0;
        var total_rows: usize = 0;
        var total_bytes: usize = 0;
        var emitted = false;

        while (true) switch (statement.step() catch |err| return failure(err)) {
            .done => break,
            .row => {
                if (total_rows == max_result_rows) return .rejected;
                var row = PageWriter.init(&row_buffer);
                writeRow(&row, &statement, column_count) catch return .misuse;
                if (page.remaining() < row.at) {
                    if (row_count == 0) return .misuse;
                    patchRowCount(&page, row_count);
                    if (page.at > max_result_bytes - total_bytes) return .rejected;
                    total_bytes += page.at;
                    page_fn(page_context, page.written());
                    emitted = true;
                    page = PageWriter.init(&page_buffer);
                    writeHeader(&page, &statement, column_count) catch return .misuse;
                    row_count = 0;
                }
                page.writeRaw(row.written()) catch return .misuse;
                row_count += 1;
                total_rows += 1;
                if (row_count == default_page_rows) {
                    patchRowCount(&page, row_count);
                    if (page.at > max_result_bytes - total_bytes) return .rejected;
                    total_bytes += page.at;
                    page_fn(page_context, page.written());
                    emitted = true;
                    page = PageWriter.init(&page_buffer);
                    writeHeader(&page, &statement, column_count) catch return .misuse;
                    row_count = 0;
                }
            },
        };

        if (row_count > 0 or !emitted) {
            patchRowCount(&page, row_count);
            if (page.at > max_result_bytes - total_bytes) return .rejected;
            page_fn(page_context, page.written());
        }
        return .ok;
    }

    /// Execute the complete statement array in one IMMEDIATE transaction.
    /// Every member is prepared separately, fully bound, and required not to
    /// yield rows; any failure rolls the whole batch back.
    pub fn exec(self: *Database, statements: []const Statement) Outcome {
        if (statements.len == 0 or statements.len > max_exec_statements) return .rejected;
        var parameter_bytes: usize = 0;
        for (statements) |item| {
            if (!validSql(item.sql) or item.params.len > max_parameters) return .rejected;
            parameter_bytes = accumulateParameterBytes(item.params, parameter_bytes) orelse return .rejected;
            if (parameter_bytes > max_exec_parameter_bytes) return .rejected;
        }

        self.lockWrite();
        defer self.unlockWrite();
        self.transaction_table_count = 0;
        self.transaction_all_tables = false;
        self.write_db.installUpdateHook(self, updateHook);
        defer self.write_db.installUpdateHook(null, null);
        self.write_db.exec("BEGIN IMMEDIATE;") catch |err| return failure(err);
        var committed = false;
        defer if (!committed) self.write_db.exec("ROLLBACK;") catch {};
        var observer: sqlite.RelationalWriteObserver = .{ .context = self, .write_fn = observeWrite, .all_fn = observeAllWrites };
        self.write_db.installRelationalExecAuthorizer(&observer) catch |err| return failure(err);
        defer self.write_db.installRelationalAuthorizer() catch {};

        for (statements) |item| {
            const sql_z = self.allocator.dupeZ(u8, item.sql) catch return .io_failed;
            defer self.allocator.free(sql_z);
            var statement = self.write_db.prepareOne(sql_z) catch |err| return failure(err);
            defer statement.finalize();
            if (statement.readOnly() or statement.parameterCount() != item.params.len) return .misuse;
            bindAll(&statement, item.params) catch |err| return failure(err);
            if ((statement.step() catch |err| return failure(err)) != .done) return .misuse;
        }
        self.write_db.installRelationalAuthorizer() catch |err| return failure(err);
        self.write_db.exec("COMMIT;") catch |err| return failure(err);
        committed = true;
        self.publishTransactionChanges();
        return .ok;
    }

    fn queryBound(context: *anyopaque, sql_text: []const u8, params: []const Value, page_context: *anyopaque, page_fn: PageFn) Outcome {
        const self: *Database = @ptrCast(@alignCast(context));
        return self.query(sql_text, params, page_context, page_fn);
    }

    fn execBound(context: *anyopaque, statements: []const Statement) Outcome {
        const self: *Database = @ptrCast(@alignCast(context));
        return self.exec(statements);
    }

    fn changesBound(context: *anyopaque, after_revision: u64) ChangeBatch {
        const self: *Database = @ptrCast(@alignCast(context));
        self.lockWrite();
        defer self.unlockWrite();
        if (self.revision <= after_revision) return .{ .revision = self.revision, .tables = &.{} };
        return .{
            .revision = self.revision,
            .tables = self.changed_tables[0..self.changed_table_count],
            .all_tables = self.changed_all_tables,
        };
    }

    fn publishTransactionChanges(self: *Database) void {
        if (self.transaction_table_count == 0 and !self.transaction_all_tables) return;
        self.changed_table_count = self.transaction_table_count;
        @memcpy(self.changed_tables[0..self.transaction_table_count], self.transaction_tables[0..self.transaction_table_count]);
        self.changed_all_tables = self.transaction_all_tables;
        self.transaction_table_count = 0;
        self.transaction_all_tables = false;
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }

    fn readConnection(self: *Database) *sqlite.Connection {
        if (self.read_db) |*db| return db;
        return &self.write_db;
    }

    fn lockWrite(self: *Database) void {
        while (!self.write_mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlockWrite(self: *Database) void {
        self.write_mutex.unlock();
    }

    fn lockRead(self: *Database) void {
        const mutex = if (self.read_db != null) &self.read_mutex else &self.write_mutex;
        while (!mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlockRead(self: *Database) void {
        const mutex = if (self.read_db != null) &self.read_mutex else &self.write_mutex;
        mutex.unlock();
    }
};

fn updateHook(context: ?*anyopaque, action: c_int, _: ?[*:0]const u8, table_z: ?[*:0]const u8, _: i64) callconv(.c) void {
    _ = sqlite.updateOperation(action) orelse return;
    const self: *Database = @ptrCast(@alignCast(context orelse return));
    const table = if (table_z) |name| std.mem.span(name) else return;
    observeWrite(self, table);
}

fn observeWrite(context: *anyopaque, table: []const u8) void {
    const self: *Database = @ptrCast(@alignCast(context));
    if (table.len == 0 or table.len > max_table_name_bytes or std.mem.startsWith(u8, table, "sqlite_")) return;
    for (self.transaction_tables[0..self.transaction_table_count]) |entry| {
        if (std.mem.eql(u8, entry.name(), table)) return;
    }
    if (self.transaction_table_count == self.transaction_tables.len) {
        self.transaction_all_tables = true;
        return;
    }
    const entry = &self.transaction_tables[self.transaction_table_count];
    entry.len = @intCast(table.len);
    @memcpy(entry.bytes[0..table.len], table);
    self.transaction_table_count += 1;
}

fn observeAllWrites(context: *anyopaque) void {
    const self: *Database = @ptrCast(@alignCast(context));
    self.transaction_all_tables = true;
}

fn validMigrations(migrations: []const Migration) bool {
    if (migrations.len > max_migrations) return false;
    var expected: u32 = 1;
    for (migrations) |migration| {
        if (migration.version != expected or migration.name.len == 0 or migration.sql.len == 0 or migration.sql.len > max_migration_bytes or
            std.mem.indexOfScalar(u8, migration.sql, 0) != null) return false;
        expected += 1;
    }
    return true;
}

pub fn outcomeName(outcome: Outcome) []const u8 {
    return @tagName(outcome);
}

fn initializeWriter(db: *sqlite.Connection, durable: bool) !void {
    if (durable) {
        try db.exec("PRAGMA journal_mode=WAL;");
        try db.exec("PRAGMA synchronous=NORMAL;");
    }
    try db.exec("PRAGMA busy_timeout=250;");
    try db.exec("PRAGMA foreign_keys=ON;");
}

fn validSql(sql_text: []const u8) bool {
    return sql_text.len > 0 and sql_text.len <= max_sql_bytes and std.mem.indexOfScalar(u8, sql_text, 0) == null;
}

fn validParameters(params: []const Value, byte_limit: usize) bool {
    if (params.len > max_parameters) return false;
    return (accumulateParameterBytes(params, 0) orelse return false) <= byte_limit;
}

fn accumulateParameterBytes(params: []const Value, initial: usize) ?usize {
    var total = initial;
    for (params) |value| switch (value) {
        .text => |bytes| {
            if (!std.unicode.utf8ValidateSlice(bytes)) return null;
            total = std.math.add(usize, total, bytes.len) catch return null;
        },
        .blob => |bytes| total = std.math.add(usize, total, bytes.len) catch return null,
        .real => |number| if (!std.math.isFinite(number)) return null,
        else => {},
    };
    return total;
}

fn bindAll(statement: *sqlite.Statement, params: []const Value) sqlite.Error!void {
    for (params, 0..) |value, index| {
        const parameter_index: c_int = @intCast(index + 1);
        switch (value) {
            .null_value => try statement.bindNull(parameter_index),
            .integer => |number| try statement.bindInt(parameter_index, number),
            .real => |number| try statement.bindFloat(parameter_index, number),
            .text => |bytes| try statement.bindText(parameter_index, bytes),
            .blob => |bytes| try statement.bindBlob(parameter_index, bytes),
        }
    }
}

fn failure(err: sqlite.Error) Outcome {
    return switch (err) {
        error.Constraint => .constraint,
        error.Busy => .busy,
        error.Corrupt => .corrupt,
        error.Misuse => .misuse,
        else => .io_failed,
    };
}

/// Page dialect (little-endian): column-count u32, row-count u32, each
/// column name as u32+bytes, then row-major values tagged null=0,
/// integer=1+i64, real=2+f64 bits, text=3+u32+bytes, blob=4+u32+bytes.
fn writeHeader(writer: *PageWriter, statement: *const sqlite.Statement, column_count: usize) error{NoSpace}!void {
    try writer.writeInt(u32, @intCast(column_count));
    try writer.writeInt(u32, 0);
    for (0..column_count) |index| {
        const name = statement.columnName(@intCast(index));
        if (!std.unicode.utf8ValidateSlice(name)) return error.NoSpace;
        try writer.writeBytes(name);
    }
}

fn writeRow(writer: *PageWriter, statement: *const sqlite.Statement, column_count: usize) error{NoSpace}!void {
    for (0..column_count) |index| {
        const column: c_int = @intCast(index);
        switch (statement.columnType(column)) {
            .null => try writer.writeByte(0),
            .integer => {
                try writer.writeByte(1);
                try writer.writeInt(i64, statement.columnInt(column));
            },
            .float => {
                const number = statement.columnFloat(column);
                if (!std.math.isFinite(number)) return error.NoSpace;
                try writer.writeByte(2);
                try writer.writeInt(u64, @bitCast(number));
            },
            .text => {
                const text = statement.columnText(column);
                if (!std.unicode.utf8ValidateSlice(text)) return error.NoSpace;
                try writer.writeByte(3);
                try writer.writeBytes(text);
            },
            .blob => {
                try writer.writeByte(4);
                try writer.writeBytes(statement.columnBlob(column));
            },
        }
    }
}

/// Validate one encoded query page before replay feeds journal bytes into an
/// app. This is deliberately structural and total: damaged lengths, tags,
/// non-finite REALs, invalid UTF-8, and trailing bytes all refuse replay.
pub fn validEncodedPage(bytes: []const u8) bool {
    if (bytes.len < 8 or bytes.len > max_page_bytes) return false;
    var at: usize = 0;
    const column_count = readPageU32(bytes, &at) orelse return false;
    const row_count = readPageU32(bytes, &at) orelse return false;
    if (row_count > default_page_rows) return false;
    for (0..column_count) |_| {
        const name = readPageBytes(bytes, &at) orelse return false;
        if (!std.unicode.utf8ValidateSlice(name)) return false;
    }
    const value_count = std.math.mul(usize, column_count, row_count) catch return false;
    for (0..value_count) |_| {
        if (at >= bytes.len) return false;
        const tag = bytes[at];
        at += 1;
        switch (tag) {
            0 => {},
            1 => if (takePageBytes(bytes, &at, 8) == null) return false,
            2 => {
                const raw = takePageBytes(bytes, &at, 8) orelse return false;
                const number: f64 = @bitCast(std.mem.readInt(u64, raw[0..8], .little));
                if (!std.math.isFinite(number)) return false;
            },
            3 => {
                const text = readPageBytes(bytes, &at) orelse return false;
                if (!std.unicode.utf8ValidateSlice(text)) return false;
            },
            4 => if (readPageBytes(bytes, &at) == null) return false,
            else => return false,
        }
    }
    return at == bytes.len;
}

fn readPageU32(bytes: []const u8, at: *usize) ?usize {
    const raw = takePageBytes(bytes, at, 4) orelse return null;
    return std.mem.readInt(u32, raw[0..4], .little);
}

fn readPageBytes(bytes: []const u8, at: *usize) ?[]const u8 {
    const len = readPageU32(bytes, at) orelse return null;
    return takePageBytes(bytes, at, len);
}

fn takePageBytes(bytes: []const u8, at: *usize, len: usize) ?[]const u8 {
    const end = std.math.add(usize, at.*, len) catch return null;
    if (end > bytes.len) return null;
    const result = bytes[at.*..end];
    at.* = end;
    return result;
}

fn patchRowCount(writer: *PageWriter, row_count: u32) void {
    std.debug.assert(writer.at >= 8);
    std.mem.writeInt(u32, writer.buffer[4..8], row_count, .little);
}

const PageWriter = struct {
    buffer: []u8,
    at: usize = 0,

    fn init(buffer: []u8) PageWriter {
        return .{ .buffer = buffer };
    }

    fn remaining(self: *const PageWriter) usize {
        return self.buffer.len - self.at;
    }

    fn written(self: *const PageWriter) []const u8 {
        return self.buffer[0..self.at];
    }

    fn writeByte(self: *PageWriter, value: u8) error{NoSpace}!void {
        if (self.remaining() < 1) return error.NoSpace;
        self.buffer[self.at] = value;
        self.at += 1;
    }

    fn writeInt(self: *PageWriter, comptime T: type, value: T) error{NoSpace}!void {
        if (self.remaining() < @sizeOf(T)) return error.NoSpace;
        std.mem.writeInt(T, self.buffer[self.at..][0..@sizeOf(T)], value, .little);
        self.at += @sizeOf(T);
    }

    fn writeRaw(self: *PageWriter, bytes: []const u8) error{NoSpace}!void {
        if (self.remaining() < bytes.len) return error.NoSpace;
        @memcpy(self.buffer[self.at..][0..bytes.len], bytes);
        self.at += bytes.len;
    }

    fn writeBytes(self: *PageWriter, bytes: []const u8) error{NoSpace}!void {
        if (bytes.len > std.math.maxInt(u32) or self.remaining() < 4 + bytes.len) return error.NoSpace;
        try self.writeInt(u32, @intCast(bytes.len));
        try self.writeRaw(bytes);
    }
};

const CapturedPages = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayList([]u8) = .empty,

    fn capture(context: *anyopaque, bytes: []const u8) void {
        const self: *CapturedPages = @ptrCast(@alignCast(context));
        self.pages.append(self.allocator, self.allocator.dupe(u8, bytes) catch @panic("test allocation failed")) catch @panic("test allocation failed");
    }

    fn deinit(self: *CapturedPages) void {
        for (self.pages.items) |page| self.allocator.free(page);
        self.pages.deinit(self.allocator);
    }
};

test "relational exec is atomic and queries emit typed pages" {
    var database = try Database.openMemory(std.testing.allocator);
    defer database.deinit();
    try std.testing.expectEqual(Outcome.ok, database.exec(&.{
        .{ .sql = "CREATE TABLE note(id INTEGER PRIMARY KEY, title TEXT NOT NULL, score REAL, body BLOB);" },
        .{ .sql = "INSERT INTO note(id,title,score,body) VALUES(?1,?2,?3,?4);", .params = &.{ .{ .integer = 7 }, .{ .text = "hello" }, .{ .real = 1.5 }, .{ .blob = "raw" } } },
    }));

    var captured: CapturedPages = .{ .allocator = std.testing.allocator };
    defer captured.deinit();
    try std.testing.expectEqual(Outcome.ok, database.query(
        "SELECT id,title,score,body,NULL AS absent FROM note WHERE id=?1;",
        &.{.{ .integer = 7 }},
        &captured,
        CapturedPages.capture,
    ));
    try std.testing.expectEqual(@as(usize, 1), captured.pages.items.len);
    const page = captured.pages.items[0];
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, page[0..4], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, page[4..8], .little));
}

test "changed-table overflow conservatively invalidates every live query" {
    var database = try Database.openMemory(std.testing.allocator);
    defer database.deinit();

    database.transaction_table_count = max_changed_tables;
    updateHook(&database, 18, null, "overflow_table", 1);
    try std.testing.expect(database.transaction_all_tables);

    database.publishTransactionChanges();
    const changes = Database.changesBound(&database, 0);
    try std.testing.expect(changes.all_tables);
    try std.testing.expectEqual(@as(u64, 1), changes.revision);
}

test "relational schema changes conservatively invalidate every live query" {
    var database = try Database.openMemory(std.testing.allocator);
    defer database.deinit();

    try std.testing.expectEqual(Outcome.ok, database.exec(&.{.{ .sql = "CREATE TABLE note(id INTEGER PRIMARY KEY) STRICT;" }}));
    const before_alter = database.revision;
    try std.testing.expectEqual(Outcome.ok, database.exec(&.{.{ .sql = "ALTER TABLE note RENAME TO notes;" }}));

    const changes = Database.changesBound(&database, before_alter);
    try std.testing.expect(changes.all_tables);
    try std.testing.expect(changes.revision > before_alter);
}

test "relational exec rolls every statement back on constraint failure" {
    var database = try Database.openMemory(std.testing.allocator);
    defer database.deinit();
    try std.testing.expectEqual(Outcome.ok, database.exec(&.{.{ .sql = "CREATE TABLE item(id INTEGER PRIMARY KEY);" }}));
    try std.testing.expectEqual(Outcome.constraint, database.exec(&.{
        .{ .sql = "INSERT INTO item(id) VALUES(?1);", .params = &.{.{ .integer = 1 }} },
        .{ .sql = "INSERT INTO item(id) VALUES(?1);", .params = &.{.{ .integer = 1 }} },
    }));
    var captured: CapturedPages = .{ .allocator = std.testing.allocator };
    defer captured.deinit();
    try std.testing.expectEqual(Outcome.ok, database.query("SELECT id FROM item;", &.{}, &captured, CapturedPages.capture));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, captured.pages.items[0][4..8], .little));
}

test "relational migrations advance atomically and refuse downgrades" {
    var database = try Database.openMemory(std.testing.allocator);
    defer database.deinit();
    const migrations = [_]Migration{
        .{ .version = 1, .name = "init", .sql = "CREATE TABLE folder(id INTEGER PRIMARY KEY) STRICT;" },
        .{ .version = 2, .name = "notes", .sql = "CREATE TABLE note(id INTEGER PRIMARY KEY, folder_id INTEGER NOT NULL REFERENCES folder(id)) STRICT;" },
    };
    const opened = database.applyMigrations(&migrations);
    try std.testing.expectEqual(OpenOutcome.ok, opened.outcome);
    try std.testing.expectEqual(@as(u32, 2), try database.schemaVersion());
    try std.testing.expectEqual(OpenOutcome.version_unknown, database.applyMigrations(migrations[0..1]).outcome);

    var failed = try Database.openMemory(std.testing.allocator);
    defer failed.deinit();
    const broken = [_]Migration{
        .{ .version = 1, .name = "init", .sql = "CREATE TABLE durable(id INTEGER PRIMARY KEY) STRICT;" },
        .{ .version = 2, .name = "broken", .sql = "CREATE TABLE durable(id INTEGER);" },
    };
    try std.testing.expectEqual(OpenOutcome.migrate_failed, failed.applyMigrations(&broken).outcome);
    try std.testing.expectEqual(@as(u32, 0), try failed.schemaVersion());
    var captured: CapturedPages = .{ .allocator = std.testing.allocator };
    defer captured.deinit();
    try std.testing.expectEqual(Outcome.misuse, failed.query("SELECT id FROM durable;", &.{}, &captured, CapturedPages.capture));
}

test "relational committed transactions publish their changed table set" {
    var database = try Database.openMemory(std.testing.allocator);
    defer database.deinit();
    try std.testing.expectEqual(Outcome.ok, database.exec(&.{
        .{ .sql = "CREATE TABLE folder(id INTEGER PRIMARY KEY) STRICT;" },
        .{ .sql = "CREATE TABLE note(id INTEGER PRIMARY KEY, folder_id INTEGER) STRICT;" },
        .{ .sql = "INSERT INTO folder(id) VALUES(1);" },
        .{ .sql = "INSERT INTO note(id,folder_id) VALUES(1,1);" },
    }));
    const first = database.binding().changes_fn(&database, 0);
    try std.testing.expectEqual(@as(usize, 2), first.tables.len);
    try std.testing.expect(first.revision > 0);
    try std.testing.expectEqual(Outcome.ok, database.exec(&.{.{ .sql = "INSERT INTO note(id,folder_id) VALUES(2,NULL);" }}));
    const second = database.binding().changes_fn(&database, first.revision);
    try std.testing.expectEqual(@as(usize, 1), second.tables.len);
    try std.testing.expectEqualStrings("note", second.tables[0].name());
}

test "authorizer write targets invalidate WITHOUT ROWID and truncate deletes" {
    var database = try Database.openMemory(std.testing.allocator);
    defer database.deinit();
    try std.testing.expectEqual(Outcome.ok, database.exec(&.{.{
        .sql = "CREATE TABLE compact(key TEXT PRIMARY KEY) STRICT, WITHOUT ROWID;",
    }}));
    var revision = database.binding().changes_fn(&database, 0).revision;

    try std.testing.expectEqual(Outcome.ok, database.exec(&.{.{
        .sql = "INSERT INTO compact(key) VALUES(?1);",
        .params = &.{.{ .text = "present" }},
    }}));
    var changes = database.binding().changes_fn(&database, revision);
    try std.testing.expectEqual(@as(usize, 1), changes.tables.len);
    try std.testing.expectEqualStrings("compact", changes.tables[0].name());
    revision = changes.revision;

    try std.testing.expectEqual(Outcome.ok, database.exec(&.{.{ .sql = "DELETE FROM compact;" }}));
    changes = database.binding().changes_fn(&database, revision);
    try std.testing.expectEqual(@as(usize, 1), changes.tables.len);
    try std.testing.expectEqualStrings("compact", changes.tables[0].name());
}

test "relational exec members cannot terminate the engine transaction" {
    var database = try Database.openMemory(std.testing.allocator);
    defer database.deinit();
    try std.testing.expectEqual(Outcome.ok, database.exec(&.{.{ .sql = "CREATE TABLE item(id INTEGER PRIMARY KEY) STRICT;" }}));
    try std.testing.expectEqual(Outcome.misuse, database.exec(&.{
        .{ .sql = "INSERT INTO item(id) VALUES(1);" },
        .{ .sql = "COMMIT;" },
        .{ .sql = "INSERT INTO item(id) VALUES(2);" },
    }));

    var captured: CapturedPages = .{ .allocator = std.testing.allocator };
    defer captured.deinit();
    try std.testing.expectEqual(Outcome.ok, database.query("SELECT id FROM item;", &.{}, &captured, CapturedPages.capture));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, captured.pages.items[0][4..8], .little));
}

test "relational migrations cannot terminate the engine transaction" {
    var database = try Database.openMemory(std.testing.allocator);
    defer database.deinit();
    const migrations = [_]Migration{.{
        .version = 1,
        .name = "bad_commit",
        .sql = "CREATE TABLE item(id INTEGER PRIMARY KEY) STRICT; COMMIT;",
    }};
    try std.testing.expectEqual(OpenOutcome.migrate_failed, database.applyMigrations(&migrations).outcome);
    try std.testing.expectEqual(@as(u32, 0), try database.schemaVersion());
}

test "relational SQLite build enables the documented FTS5 and JSON features" {
    var database = try Database.openMemory(std.testing.allocator);
    defer database.deinit();
    try std.testing.expectEqual(Outcome.ok, database.exec(&.{
        .{ .sql = "CREATE VIRTUAL TABLE search_index USING fts5(body);" },
        .{ .sql = "INSERT INTO search_index(body) VALUES(?1);", .params = &.{.{ .text = "relational storage" }} },
    }));

    var captured: CapturedPages = .{ .allocator = std.testing.allocator };
    defer captured.deinit();
    try std.testing.expectEqual(Outcome.ok, database.query(
        "SELECT json_extract('{\"answer\":42}', '$.answer') AS answer FROM search_index WHERE search_index MATCH 'storage';",
        &.{},
        &captured,
        CapturedPages.capture,
    ));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, captured.pages.items[0][4..8], .little));
}

test "relational SQL cannot escape the engine-owned database or schema version" {
    var database = try Database.openMemory(std.testing.allocator);
    defer database.deinit();
    try std.testing.expectEqual(Outcome.misuse, database.exec(&.{.{ .sql = "ATTACH DATABASE ':memory:' AS escaped;" }}));
    try std.testing.expectEqual(Outcome.misuse, database.exec(&.{.{ .sql = "PRAGMA user_version=9;" }}));

    var captured: CapturedPages = .{ .allocator = std.testing.allocator };
    defer captured.deinit();
    try std.testing.expectEqual(Outcome.ok, database.query("PRAGMA user_version;", &.{}, &captured, CapturedPages.capture));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, captured.pages.items[0][4..8], .little));
}

test "relational pages refuse values outside the cross-language dialect" {
    var database = try Database.openMemory(std.testing.allocator);
    defer database.deinit();
    var captured: CapturedPages = .{ .allocator = std.testing.allocator };
    defer captured.deinit();
    try std.testing.expectEqual(Outcome.misuse, database.query("SELECT 1e999;", &.{}, &captured, CapturedPages.capture));
    try std.testing.expectEqual(Outcome.misuse, database.query("SELECT CAST(x'80' AS TEXT);", &.{}, &captured, CapturedPages.capture));
    try std.testing.expectEqual(@as(usize, 0), captured.pages.items.len);
}
