//! Small internal SQLite seam shared by the record store and the relational
//! storage tier. SQLite remains an implementation detail: apps receive inert
//! effects, never a synchronous database handle.

const std = @import("std");

/// The tiny stable SQLite C ABI this engine uses. Keeping the declarations
/// here instead of translating sqlite3.h is load-bearing for capability
/// shedding: every app may import the SDK's effect types, while only apps
/// declaring `store` or `sqlite` compile and link the amalgamation itself.
/// SQLite's public ABI and these numeric constants are explicitly stable.
const c = struct {
    const sqlite3 = opaque {};
    const sqlite3_stmt = opaque {};

    const SQLITE_OK: c_int = 0;
    const SQLITE_ERROR: c_int = 1;
    const SQLITE_BUSY: c_int = 5;
    const SQLITE_LOCKED: c_int = 6;
    const SQLITE_IOERR: c_int = 10;
    const SQLITE_CORRUPT: c_int = 11;
    const SQLITE_CONSTRAINT: c_int = 19;
    const SQLITE_MISUSE: c_int = 21;
    const SQLITE_AUTH: c_int = 23;
    const SQLITE_NOTADB: c_int = 26;
    const SQLITE_ROW: c_int = 100;
    const SQLITE_DONE: c_int = 101;

    const SQLITE_INTEGER: c_int = 1;
    const SQLITE_FLOAT: c_int = 2;
    const SQLITE_TEXT: c_int = 3;
    const SQLITE_BLOB: c_int = 4;
    const SQLITE_NULL: c_int = 5;

    const SQLITE_OK_AUTHORIZER: c_int = 0;
    const SQLITE_DENY_AUTHORIZER: c_int = 1;
    const SQLITE_CREATE_INDEX: c_int = 1;
    const SQLITE_CREATE_TEMP_INDEX: c_int = 3;
    const SQLITE_CREATE_TEMP_TABLE: c_int = 4;
    const SQLITE_CREATE_TEMP_TRIGGER: c_int = 5;
    const SQLITE_CREATE_TEMP_VIEW: c_int = 6;
    const SQLITE_CREATE_VIEW: c_int = 8;
    const SQLITE_DROP_INDEX: c_int = 10;
    const SQLITE_DROP_TEMP_INDEX: c_int = 12;
    const SQLITE_DROP_TEMP_TABLE: c_int = 13;
    const SQLITE_DROP_TEMP_TRIGGER: c_int = 14;
    const SQLITE_DROP_TEMP_VIEW: c_int = 15;
    const SQLITE_DROP_VIEW: c_int = 17;
    const SQLITE_PRAGMA: c_int = 19;
    const SQLITE_TRANSACTION: c_int = 22;
    const SQLITE_ATTACH: c_int = 24;
    const SQLITE_DETACH: c_int = 25;
    const SQLITE_ALTER_TABLE: c_int = 26;
    const SQLITE_CREATE_VTABLE: c_int = 29;
    const SQLITE_DROP_VTABLE: c_int = 30;
    const SQLITE_SAVEPOINT: c_int = 32;

    const SQLITE_INSERT: c_int = 18;
    const SQLITE_DELETE: c_int = 9;
    const SQLITE_UPDATE: c_int = 23;

    const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
    const SQLITE_OPEN_CREATE: c_int = 0x00000004;
    const SQLITE_OPEN_FULLMUTEX: c_int = 0x00010000;

    // Keep the references strong: a store-capable build that forgets to link
    // the engine must fail at link time. The ordinary TestHarness is a
    // separate type from RecordStoreTestHarness, so no-store app tests never
    // analyze these calls merely through SDK reflection.
    const linkage: std.builtin.GlobalLinkage = .strong;
    const sqlite3_open_v2 = @extern(*allowzero const fn ([*:0]const u8, *?*sqlite3, c_int, ?[*:0]const u8) callconv(.c) c_int, .{ .name = "sqlite3_open_v2", .linkage = linkage });
    const sqlite3_close_v2 = @extern(*allowzero const fn (*sqlite3) callconv(.c) c_int, .{ .name = "sqlite3_close_v2", .linkage = linkage });
    const sqlite3_exec = @extern(*allowzero const fn (*sqlite3, [*:0]const u8, ?*const anyopaque, ?*anyopaque, ?*?[*:0]u8) callconv(.c) c_int, .{ .name = "sqlite3_exec", .linkage = linkage });
    const sqlite3_set_authorizer = @extern(*allowzero const fn (*sqlite3, ?*const fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int, ?*anyopaque) callconv(.c) c_int, .{ .name = "sqlite3_set_authorizer", .linkage = linkage });
    const sqlite3_update_hook = @extern(*allowzero const fn (*sqlite3, ?*const fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, i64) callconv(.c) void, ?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "sqlite3_update_hook", .linkage = linkage });
    const sqlite3_prepare_v2 = @extern(*allowzero const fn (*sqlite3, [*:0]const u8, c_int, *?*sqlite3_stmt, ?*?[*:0]const u8) callconv(.c) c_int, .{ .name = "sqlite3_prepare_v2", .linkage = linkage });
    const sqlite3_finalize = @extern(*allowzero const fn (*sqlite3_stmt) callconv(.c) c_int, .{ .name = "sqlite3_finalize", .linkage = linkage });
    const sqlite3_reset = @extern(*allowzero const fn (*sqlite3_stmt) callconv(.c) c_int, .{ .name = "sqlite3_reset", .linkage = linkage });
    const sqlite3_clear_bindings = @extern(*allowzero const fn (*sqlite3_stmt) callconv(.c) c_int, .{ .name = "sqlite3_clear_bindings", .linkage = linkage });
    const sqlite3_bind_null = @extern(*allowzero const fn (*sqlite3_stmt, c_int) callconv(.c) c_int, .{ .name = "sqlite3_bind_null", .linkage = linkage });
    const sqlite3_bind_int64 = @extern(*allowzero const fn (*sqlite3_stmt, c_int, i64) callconv(.c) c_int, .{ .name = "sqlite3_bind_int64", .linkage = linkage });
    const sqlite3_bind_double = @extern(*allowzero const fn (*sqlite3_stmt, c_int, f64) callconv(.c) c_int, .{ .name = "sqlite3_bind_double", .linkage = linkage });
    const sqlite3_bind_text = @extern(*allowzero const fn (*sqlite3_stmt, c_int, [*]const u8, c_int, ?*const anyopaque) callconv(.c) c_int, .{ .name = "sqlite3_bind_text", .linkage = linkage });
    const sqlite3_bind_zeroblob64 = @extern(*allowzero const fn (*sqlite3_stmt, c_int, u64) callconv(.c) c_int, .{ .name = "sqlite3_bind_zeroblob64", .linkage = linkage });
    const sqlite3_bind_blob64 = @extern(*allowzero const fn (*sqlite3_stmt, c_int, ?*const anyopaque, u64, ?*const anyopaque) callconv(.c) c_int, .{ .name = "sqlite3_bind_blob64", .linkage = linkage });
    const sqlite3_bind_parameter_count = @extern(*allowzero const fn (*sqlite3_stmt) callconv(.c) c_int, .{ .name = "sqlite3_bind_parameter_count", .linkage = linkage });
    const sqlite3_stmt_readonly = @extern(*allowzero const fn (*sqlite3_stmt) callconv(.c) c_int, .{ .name = "sqlite3_stmt_readonly", .linkage = linkage });
    const sqlite3_step = @extern(*allowzero const fn (*sqlite3_stmt) callconv(.c) c_int, .{ .name = "sqlite3_step", .linkage = linkage });
    const sqlite3_column_count = @extern(*allowzero const fn (*sqlite3_stmt) callconv(.c) c_int, .{ .name = "sqlite3_column_count", .linkage = linkage });
    const sqlite3_column_name = @extern(*allowzero const fn (*sqlite3_stmt, c_int) callconv(.c) ?[*:0]const u8, .{ .name = "sqlite3_column_name", .linkage = linkage });
    const sqlite3_column_type = @extern(*allowzero const fn (*sqlite3_stmt, c_int) callconv(.c) c_int, .{ .name = "sqlite3_column_type", .linkage = linkage });
    const sqlite3_column_bytes = @extern(*allowzero const fn (*sqlite3_stmt, c_int) callconv(.c) c_int, .{ .name = "sqlite3_column_bytes", .linkage = linkage });
    const sqlite3_column_blob = @extern(*allowzero const fn (*sqlite3_stmt, c_int) callconv(.c) ?*const anyopaque, .{ .name = "sqlite3_column_blob", .linkage = linkage });
    const sqlite3_column_text = @extern(*allowzero const fn (*sqlite3_stmt, c_int) callconv(.c) ?[*]const u8, .{ .name = "sqlite3_column_text", .linkage = linkage });
    const sqlite3_column_int64 = @extern(*allowzero const fn (*sqlite3_stmt, c_int) callconv(.c) i64, .{ .name = "sqlite3_column_int64", .linkage = linkage });
    const sqlite3_column_double = @extern(*allowzero const fn (*sqlite3_stmt, c_int) callconv(.c) f64, .{ .name = "sqlite3_column_double", .linkage = linkage });
};

pub const Error = error{
    Busy,
    OpenFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    ExecFailed,
    Constraint,
    Corrupt,
    IoFailed,
    Misuse,
};

pub const Step = enum { row, done };

pub const RelationalWriteObserver = struct {
    context: *anyopaque,
    write_fn: *const fn (context: *anyopaque, table: []const u8) void,
    all_fn: *const fn (context: *anyopaque) void,
};

pub const Connection = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) Error!Connection {
        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(path.ptr, &handle, flags, null) != c.SQLITE_OK) {
            if (handle) |opened| _ = c.sqlite3_close_v2(opened);
            return error.OpenFailed;
        }
        return .{ .handle = handle orelse return error.OpenFailed };
    }

    pub fn close(self: *Connection) void {
        _ = c.sqlite3_close_v2(self.handle);
    }

    pub fn exec(self: *Connection, sql: [:0]const u8) Error!void {
        const result = c.sqlite3_exec(self.handle, sql.ptr, null, null, null);
        if (result != c.SQLITE_OK) return classify(result, error.ExecFailed);
    }

    /// Install the relational tier's SQL sandbox. The database is app-owned,
    /// but SQL may not escape its engine-owned file with ATTACH/DETACH (VACUUM
    /// INTO is authorized as ATTACH), or mutate lifecycle PRAGMAs the runtime
    /// owns. Record-store connections do not install this policy.
    pub fn installRelationalAuthorizer(self: *Connection) Error!void {
        const result = c.sqlite3_set_authorizer(self.handle, relationalAuthorizer, null);
        if (result != c.SQLITE_OK) return classify(result, error.Misuse);
    }

    /// Temporarily remove/reinstall the app-SQL authorizer around one
    /// engine-owned lifecycle operation (migrations and `user_version`).
    /// Callers must hold their connection's writer lock.
    pub fn setRelationalAuthorizer(self: *Connection, enabled: bool) Error!void {
        const callback: ?*const @TypeOf(relationalAuthorizer) = if (enabled) relationalAuthorizer else null;
        const result = c.sqlite3_set_authorizer(self.handle, callback, null);
        if (result != c.SQLITE_OK) return classify(result, error.Misuse);
    }

    /// Install the app-exec policy while a statement array is being prepared
    /// and stepped. Authorizer write events cover cases sqlite3_update_hook
    /// deliberately omits, including WITHOUT ROWID tables and truncate
    /// optimization. Transaction control remains engine-owned so a batch
    /// member cannot commit or roll back the surrounding transaction.
    pub fn installRelationalExecAuthorizer(self: *Connection, observer: *RelationalWriteObserver) Error!void {
        const result = c.sqlite3_set_authorizer(self.handle, relationalExecAuthorizer, observer);
        if (result != c.SQLITE_OK) return classify(result, error.Misuse);
    }

    /// Migrations may change schema, but they may not escape the relational
    /// sandbox or terminate the runtime's all-pending-migrations transaction.
    pub fn installRelationalMigrationAuthorizer(self: *Connection) Error!void {
        const result = c.sqlite3_set_authorizer(self.handle, relationalMigrationAuthorizer, null);
        if (result != c.SQLITE_OK) return classify(result, error.Misuse);
    }

    /// Install SQLite's transaction-local table-write hook. SQLite invokes
    /// it synchronously on the thread stepping the mutating statement.
    pub fn installUpdateHook(
        self: *Connection,
        context: ?*anyopaque,
        callback: ?*const fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, i64) callconv(.c) void,
    ) void {
        _ = c.sqlite3_update_hook(self.handle, callback, context);
    }

    pub fn prepare(self: *Connection, sql: [:0]const u8) Error!Statement {
        var statement: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &statement, null);
        if (result != c.SQLITE_OK) return classify(result, error.PrepareFailed);
        return .{ .handle = statement orelse return error.PrepareFailed };
    }

    /// Prepare exactly one statement. Runtime relational effects deliberately
    /// refuse stacked SQL so one query command cannot smuggle writes after a
    /// SELECT and every exec array element remains one auditable statement.
    pub fn prepareOne(self: *Connection, sql: [:0]const u8) Error!Statement {
        var statement: ?*c.sqlite3_stmt = null;
        var tail: ?[*:0]const u8 = null;
        const result = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &statement, &tail);
        if (result != c.SQLITE_OK) return classify(result, error.PrepareFailed);
        errdefer {
            if (statement) |prepared| _ = c.sqlite3_finalize(prepared);
        }
        const remaining = if (tail) |pointer| std.mem.span(pointer) else "";
        if (remaining.len > 0) {
            // Ask SQLite itself whether the tail contains another statement.
            // This accepts whitespace/comments and correctly treats trigger
            // bodies as part of the first statement without growing a second
            // SQL parser in the runtime.
            var extra: ?*c.sqlite3_stmt = null;
            const extra_result = c.sqlite3_prepare_v2(self.handle, remaining.ptr, @intCast(remaining.len), &extra, null);
            if (extra_result != c.SQLITE_OK) return classify(extra_result, error.PrepareFailed);
            if (extra) |prepared| {
                _ = c.sqlite3_finalize(prepared);
                return error.Misuse;
            }
        }
        return .{ .handle = statement orelse return error.PrepareFailed };
    }
};

pub const UpdateOperation = enum { insert, update, delete };

pub fn updateOperation(action: c_int) ?UpdateOperation {
    return switch (action) {
        c.SQLITE_INSERT => .insert,
        c.SQLITE_UPDATE => .update,
        c.SQLITE_DELETE => .delete,
        else => null,
    };
}

pub const ColumnType = enum { integer, float, text, blob, null };

pub const Statement = struct {
    handle: *c.sqlite3_stmt,

    pub fn finalize(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn reset(self: *Statement) Error!void {
        const reset_result = c.sqlite3_reset(self.handle);
        if (reset_result != c.SQLITE_OK) return classify(reset_result, error.StepFailed);
        const clear_result = c.sqlite3_clear_bindings(self.handle);
        if (clear_result != c.SQLITE_OK) return classify(clear_result, error.BindFailed);
    }

    pub fn bindInt(self: *Statement, index: c_int, value: i64) Error!void {
        const result = c.sqlite3_bind_int64(self.handle, index, value);
        if (result != c.SQLITE_OK) return classify(result, error.BindFailed);
    }

    pub fn bindNull(self: *Statement, index: c_int) Error!void {
        const result = c.sqlite3_bind_null(self.handle, index);
        if (result != c.SQLITE_OK) return classify(result, error.BindFailed);
    }

    pub fn bindFloat(self: *Statement, index: c_int, value: f64) Error!void {
        const result = c.sqlite3_bind_double(self.handle, index, value);
        if (result != c.SQLITE_OK) return classify(result, error.BindFailed);
    }

    pub fn bindText(self: *Statement, index: c_int, bytes: []const u8) Error!void {
        if (bytes.len > std.math.maxInt(c_int)) return error.BindFailed;
        const result = c.sqlite3_bind_text(self.handle, index, bytes.ptr, @intCast(bytes.len), null);
        if (result != c.SQLITE_OK) return classify(result, error.BindFailed);
    }

    pub fn bindBlob(self: *Statement, index: c_int, bytes: []const u8) Error!void {
        if (bytes.len == 0) {
            const result = c.sqlite3_bind_zeroblob64(self.handle, index, 0);
            if (result != c.SQLITE_OK) return classify(result, error.BindFailed);
            return;
        }
        const pointer: ?*const anyopaque = if (bytes.len == 0) null else bytes.ptr;
        // Callers keep every bound slice alive through step/reset/finalize, so
        // SQLITE_STATIC (a null destructor) is both correct and avoids the C
        // macro's deliberately invalid -1 function pointer, which Zig 0.16
        // refuses to materialize at comptime.
        const result = c.sqlite3_bind_blob64(self.handle, index, pointer, bytes.len, null);
        if (result != c.SQLITE_OK) return classify(result, error.BindFailed);
    }

    pub fn step(self: *Statement) Error!Step {
        const result = c.sqlite3_step(self.handle);
        return switch (result) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => classify(result, error.StepFailed),
        };
    }

    pub fn parameterCount(self: *const Statement) usize {
        return @intCast(c.sqlite3_bind_parameter_count(self.handle));
    }

    pub fn readOnly(self: *const Statement) bool {
        return c.sqlite3_stmt_readonly(self.handle) != 0;
    }

    pub fn columnCount(self: *const Statement) usize {
        return @intCast(c.sqlite3_column_count(self.handle));
    }

    pub fn columnName(self: *const Statement, index: c_int) []const u8 {
        const name = c.sqlite3_column_name(self.handle, index) orelse return "";
        return std.mem.span(name);
    }

    pub fn columnType(self: *const Statement, index: c_int) ColumnType {
        return switch (c.sqlite3_column_type(self.handle, index)) {
            c.SQLITE_INTEGER => .integer,
            c.SQLITE_FLOAT => .float,
            c.SQLITE_TEXT => .text,
            c.SQLITE_BLOB => .blob,
            c.SQLITE_NULL => .null,
            else => .null,
        };
    }

    pub fn columnBlob(self: *const Statement, index: c_int) []const u8 {
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, index));
        if (len == 0) return "";
        const raw = c.sqlite3_column_blob(self.handle, index) orelse return "";
        const bytes: [*]const u8 = @ptrCast(raw);
        return bytes[0..len];
    }

    pub fn columnInt(self: *const Statement, index: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, index);
    }

    pub fn columnFloat(self: *const Statement, index: c_int) f64 {
        return c.sqlite3_column_double(self.handle, index);
    }

    pub fn columnText(self: *const Statement, index: c_int) []const u8 {
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, index));
        if (len == 0) return "";
        const bytes = c.sqlite3_column_text(self.handle, index) orelse return "";
        return bytes[0..len];
    }
};

fn classify(result: c_int, fallback: Error) Error {
    // Extended result codes retain the primary code in the low byte.
    return switch (result & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.Corrupt,
        c.SQLITE_IOERR => error.IoFailed,
        c.SQLITE_ERROR, c.SQLITE_MISUSE, c.SQLITE_AUTH => error.Misuse,
        else => fallback,
    };
}

fn relationalAuthorizer(
    _: ?*anyopaque,
    action: c_int,
    first: ?[*:0]const u8,
    second: ?[*:0]const u8,
    _: ?[*:0]const u8,
    _: ?[*:0]const u8,
) callconv(.c) c_int {
    return relationalPolicy(action, first, second);
}

fn relationalExecAuthorizer(
    context: ?*anyopaque,
    action: c_int,
    first: ?[*:0]const u8,
    second: ?[*:0]const u8,
    _: ?[*:0]const u8,
    _: ?[*:0]const u8,
) callconv(.c) c_int {
    if (action == c.SQLITE_TRANSACTION or action == c.SQLITE_SAVEPOINT) return c.SQLITE_DENY_AUTHORIZER;
    if (schemaOperation(action)) {
        const observer: *RelationalWriteObserver = @ptrCast(@alignCast(context orelse return c.SQLITE_DENY_AUTHORIZER));
        observer.all_fn(observer.context);
    } else if (updateOperation(action) != null) {
        const observer: *RelationalWriteObserver = @ptrCast(@alignCast(context orelse return c.SQLITE_DENY_AUTHORIZER));
        const table = if (first) |value| std.mem.span(value) else "";
        if (table.len > 0) observer.write_fn(observer.context, table);
    }
    return relationalPolicy(action, first, second);
}

fn relationalMigrationAuthorizer(
    _: ?*anyopaque,
    action: c_int,
    first: ?[*:0]const u8,
    second: ?[*:0]const u8,
    _: ?[*:0]const u8,
    _: ?[*:0]const u8,
) callconv(.c) c_int {
    if (action == c.SQLITE_TRANSACTION or action == c.SQLITE_SAVEPOINT) return c.SQLITE_DENY_AUTHORIZER;
    return relationalPolicy(action, first, second);
}

fn relationalPolicy(action: c_int, first: ?[*:0]const u8, second: ?[*:0]const u8) c_int {
    if (action == c.SQLITE_ATTACH or action == c.SQLITE_DETACH) return c.SQLITE_DENY_AUTHORIZER;
    if (temporarySchemaOperation(action)) return c.SQLITE_DENY_AUTHORIZER;
    if (action == c.SQLITE_PRAGMA and second != null) {
        const name = if (first) |value| std.mem.span(value) else "";
        for (relational_owned_pragmas) |owned| {
            if (std.ascii.eqlIgnoreCase(name, owned)) return c.SQLITE_DENY_AUTHORIZER;
        }
    }
    return c.SQLITE_OK_AUTHORIZER;
}

fn temporarySchemaOperation(action: c_int) bool {
    return (action >= c.SQLITE_CREATE_TEMP_INDEX and action <= c.SQLITE_CREATE_TEMP_VIEW) or
        (action >= c.SQLITE_DROP_TEMP_INDEX and action <= c.SQLITE_DROP_TEMP_VIEW);
}

/// SQLite's schema authorizer action codes are stable and contiguous across
/// the CREATE and DROP families, including their TEMP variants. A successful
/// runtime DDL statement can change any prepared live-query shape, so callers
/// conservatively invalidate every subscription instead of trusting the DML
/// hooks, which report only sqlite_master for ALTER TABLE.
fn schemaOperation(action: c_int) bool {
    return (action >= c.SQLITE_CREATE_INDEX and action <= c.SQLITE_CREATE_VIEW) or
        (action >= c.SQLITE_DROP_INDEX and action <= c.SQLITE_DROP_VIEW) or
        action == c.SQLITE_ALTER_TABLE or action == c.SQLITE_CREATE_VTABLE or action == c.SQLITE_DROP_VTABLE;
}

const relational_owned_pragmas = [_][]const u8{
    "user_version",
    "schema_version",
    "writable_schema",
    "query_only",
    "journal_mode",
    "synchronous",
    "locking_mode",
    "foreign_keys",
    "defer_foreign_keys",
    "busy_timeout",
    "wal_autocheckpoint",
    "temp_store",
    "temp_store_directory",
    "data_store_directory",
};

test "sqlite engine opens memory databases and executes statements" {
    var db = try Connection.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (k BLOB PRIMARY KEY, v BLOB NOT NULL);");
    var insert = try db.prepare("INSERT INTO t(k,v) VALUES(?1,?2);");
    defer insert.finalize();
    try insert.bindBlob(1, "a");
    try insert.bindBlob(2, "b");
    try std.testing.expectEqual(Step.done, try insert.step());
}

test "prepareOne delegates statement boundaries to SQLite" {
    var db = try Connection.open(":memory:");
    defer db.close();

    var commented = try db.prepareOne("SELECT 1; -- one statement\n");
    defer commented.finalize();
    try std.testing.expectEqual(Step.row, try commented.step());

    try std.testing.expectError(error.Misuse, db.prepareOne("SELECT 1; ; SELECT 2;"));

    try db.exec("CREATE TABLE source(value INTEGER); CREATE TABLE audit(value INTEGER);");
    var trigger = try db.prepareOne(
        "CREATE TRIGGER source_audit AFTER INSERT ON source BEGIN INSERT INTO audit(value) VALUES(new.value); END;",
    );
    defer trigger.finalize();
    try std.testing.expectEqual(Step.done, try trigger.step());
}
