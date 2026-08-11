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
    const SQLITE_BUSY: c_int = 5;
    const SQLITE_LOCKED: c_int = 6;
    const SQLITE_ROW: c_int = 100;
    const SQLITE_DONE: c_int = 101;

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
    const sqlite3_prepare_v2 = @extern(*allowzero const fn (*sqlite3, [*:0]const u8, c_int, *?*sqlite3_stmt, ?*?[*:0]const u8) callconv(.c) c_int, .{ .name = "sqlite3_prepare_v2", .linkage = linkage });
    const sqlite3_finalize = @extern(*allowzero const fn (*sqlite3_stmt) callconv(.c) c_int, .{ .name = "sqlite3_finalize", .linkage = linkage });
    const sqlite3_reset = @extern(*allowzero const fn (*sqlite3_stmt) callconv(.c) c_int, .{ .name = "sqlite3_reset", .linkage = linkage });
    const sqlite3_clear_bindings = @extern(*allowzero const fn (*sqlite3_stmt) callconv(.c) c_int, .{ .name = "sqlite3_clear_bindings", .linkage = linkage });
    const sqlite3_bind_int64 = @extern(*allowzero const fn (*sqlite3_stmt, c_int, i64) callconv(.c) c_int, .{ .name = "sqlite3_bind_int64", .linkage = linkage });
    const sqlite3_bind_zeroblob64 = @extern(*allowzero const fn (*sqlite3_stmt, c_int, u64) callconv(.c) c_int, .{ .name = "sqlite3_bind_zeroblob64", .linkage = linkage });
    const sqlite3_bind_blob64 = @extern(*allowzero const fn (*sqlite3_stmt, c_int, ?*const anyopaque, u64, ?*const anyopaque) callconv(.c) c_int, .{ .name = "sqlite3_bind_blob64", .linkage = linkage });
    const sqlite3_step = @extern(*allowzero const fn (*sqlite3_stmt) callconv(.c) c_int, .{ .name = "sqlite3_step", .linkage = linkage });
    const sqlite3_column_bytes = @extern(*allowzero const fn (*sqlite3_stmt, c_int) callconv(.c) c_int, .{ .name = "sqlite3_column_bytes", .linkage = linkage });
    const sqlite3_column_blob = @extern(*allowzero const fn (*sqlite3_stmt, c_int) callconv(.c) ?*const anyopaque, .{ .name = "sqlite3_column_blob", .linkage = linkage });
    const sqlite3_column_int64 = @extern(*allowzero const fn (*sqlite3_stmt, c_int) callconv(.c) i64, .{ .name = "sqlite3_column_int64", .linkage = linkage });
};

pub const Error = error{
    Busy,
    OpenFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    ExecFailed,
};

pub const Step = enum { row, done };

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

    pub fn prepare(self: *Connection, sql: [:0]const u8) Error!Statement {
        var statement: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &statement, null);
        if (result != c.SQLITE_OK) return classify(result, error.PrepareFailed);
        return .{ .handle = statement orelse return error.PrepareFailed };
    }
};

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
};

fn classify(result: c_int, fallback: Error) Error {
    // Extended result codes retain the primary code in the low byte.
    return switch (result & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
        else => fallback,
    };
}

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
