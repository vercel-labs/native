//! Tier-3 relational effect coverage: SQLite executes synchronously on the
//! host side, but rows and terminals remain routed, ordered Msg values.

const std = @import("std");
const effects_mod = @import("effects.zig");
const relational_store = @import("relational_store.zig");

const Msg = union(enum) { db: effects_mod.EffectDbResult };
const Fx = effects_mod.Effects(Msg);

fn takeResult(fx: *Fx) !effects_mod.EffectDbResult {
    return if (fx.takeMsg()) |msg| msg.db else error.TestExpectedMsg;
}

test "relational effects deliver encoded pages then a done terminal" {
    var database = try relational_store.Database.openMemory(std.testing.allocator);
    defer database.deinit();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    fx.dbExec(.{ .key = 1, .statements = &.{
        .{ .sql = "CREATE TABLE note(id INTEGER PRIMARY KEY, title TEXT NOT NULL);" },
        .{ .sql = "INSERT INTO note(id,title) VALUES(?1,?2);", .params = &.{ .{ .integer = 1 }, .{ .text = "one" } } },
        .{ .sql = "INSERT INTO note(id,title) VALUES(?1,?2);", .params = &.{ .{ .integer = 2 }, .{ .text = "two" } } },
    }, .on_result = Fx.dbMsg(.db) });
    const wrote = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.exec, wrote.kind);
    try std.testing.expectEqual(effects_mod.EffectDbOutcome.ok, wrote.outcome);

    fx.dbQuery(.{
        .key = 2,
        .sql = "SELECT id,title FROM note ORDER BY id;",
        .on_result = Fx.dbMsg(.db),
    });
    const page = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.page, page.kind);
    try std.testing.expectEqual(effects_mod.EffectDbOutcome.ok, page.outcome);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, page.bytes[0..4], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, page.bytes[4..8], .little));
    const done = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.done, done.kind);
    try std.testing.expectEqual(effects_mod.EffectDbOutcome.ok, done.outcome);
    try std.testing.expectEqual(@as(usize, 0), done.bytes.len);
}

test "relational query pagination emits every row without truncation" {
    var database = try relational_store.Database.openMemory(std.testing.allocator);
    defer database.deinit();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    fx.dbQuery(.{
        .key = 22,
        .sql = "WITH RECURSIVE n(value) AS (VALUES(1) UNION ALL SELECT value + 1 FROM n WHERE value < 300) SELECT value FROM n;",
        .on_result = Fx.dbMsg(.db),
    });
    const first = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.page, first.kind);
    try std.testing.expectEqual(@as(u32, 256), std.mem.readInt(u32, first.bytes[4..8], .little));
    try std.testing.expect(first.bytes.len <= relational_store.max_page_bytes);
    const second = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.page, second.kind);
    try std.testing.expectEqual(@as(u32, 44), std.mem.readInt(u32, second.bytes[4..8], .little));
    try std.testing.expect(second.bytes.len <= relational_store.max_page_bytes);
    const done = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.done, done.kind);
    try std.testing.expect(fx.takeMsg() == null);
}

test "relational queries reject whole results beyond the total row bound" {
    var database = try relational_store.Database.openMemory(std.testing.allocator);
    defer database.deinit();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    var sql_buffer: [256]u8 = undefined;
    const sql = try std.fmt.bufPrint(
        &sql_buffer,
        "WITH RECURSIVE n(value) AS (VALUES(1) UNION ALL SELECT value + 1 FROM n WHERE value < {d}) SELECT value FROM n;",
        .{relational_store.max_result_rows + 1},
    );
    fx.dbQuery(.{ .key = 24, .sql = sql, .on_result = Fx.dbMsg(.db) });
    const rejected = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.done, rejected.kind);
    try std.testing.expectEqual(effects_mod.EffectDbOutcome.rejected, rejected.outcome);
    try std.testing.expectEqual(@as(usize, 0), rejected.bytes.len);
    try std.testing.expect(fx.takeMsg() == null);
}

test "relational exec rejects TEMP schema objects" {
    var database = try relational_store.Database.openMemory(std.testing.allocator);
    defer database.deinit();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    fx.dbExec(.{
        .key = 25,
        .statements = &.{.{ .sql = "CREATE TEMP TABLE session_note(id INTEGER PRIMARY KEY) STRICT;" }},
        .on_result = Fx.dbMsg(.db),
    });
    const rejected = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.exec, rejected.kind);
    try std.testing.expectEqual(effects_mod.EffectDbOutcome.misuse, rejected.outcome);
}

test "callback-less relational queries release staged page storage" {
    var database = try relational_store.Database.openMemory(std.testing.allocator);
    defer database.deinit();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    fx.dbQuery(.{
        .key = 23,
        .sql = "SELECT zeroblob(4096) AS payload;",
    });
    try std.testing.expect(fx.takeMsg() == null);
}

test "relational exec rolls back the whole command and reports constraint" {
    var database = try relational_store.Database.openMemory(std.testing.allocator);
    defer database.deinit();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    fx.dbExec(.{ .key = 3, .statements = &.{.{ .sql = "CREATE TABLE item(id INTEGER PRIMARY KEY);" }}, .on_result = Fx.dbMsg(.db) });
    _ = try takeResult(&fx);
    fx.dbExec(.{ .key = 4, .statements = &.{
        .{ .sql = "INSERT INTO item(id) VALUES(?1);", .params = &.{.{ .integer = 1 }} },
        .{ .sql = "INSERT INTO item(id) VALUES(?1);", .params = &.{.{ .integer = 1 }} },
    }, .on_result = Fx.dbMsg(.db) });
    const failed = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectDbOutcome.constraint, failed.outcome);

    fx.dbQuery(.{ .key = 5, .sql = "SELECT id FROM item;", .on_result = Fx.dbMsg(.db) });
    const page = try takeResult(&fx);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, page.bytes[4..8], .little));
    _ = try takeResult(&fx);
}

test "query keys replace and cancel silently while exec duplicates reject loudly" {
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.dbQuery(.{ .key = 10, .sql = "SELECT 1;", .on_result = Fx.dbMsg(.db) });
    fx.dbQuery(.{ .key = 10, .sql = "SELECT 2;", .on_result = Fx.dbMsg(.db) });
    try std.testing.expectEqual(@as(usize, 1), fx.pendingDbCount());
    fx.cancelDbQuery(10);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingDbCount());
    try std.testing.expect(fx.takeMsg() == null);

    const statements = [_]effects_mod.EffectDbStatement{.{ .sql = "CREATE TABLE duplicate(id INTEGER);" }};
    fx.dbExec(.{ .key = 11, .statements = &statements, .on_result = Fx.dbMsg(.db) });
    fx.dbExec(.{ .key = 11, .statements = &statements, .on_result = Fx.dbMsg(.db) });
    try std.testing.expectEqual(@as(usize, 1), fx.pendingDbCount());
    const rejected = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.exec, rejected.kind);
    try std.testing.expectEqual(effects_mod.EffectDbOutcome.rejected, rejected.outcome);
}

test "replacing a real relational query purges its staged pages" {
    var database = try relational_store.Database.openMemory(std.testing.allocator);
    defer database.deinit();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    fx.dbQuery(.{
        .key = 12,
        .sql = "WITH RECURSIVE n(value) AS (VALUES(1) UNION ALL SELECT value + 1 FROM n WHERE value < 300) SELECT value FROM n;",
        .on_result = Fx.dbMsg(.db),
    });
    fx.dbQuery(.{ .key = 12, .sql = "SELECT 2 AS value;", .on_result = Fx.dbMsg(.db) });
    const page = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.page, page.kind);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, page.bytes[4..8], .little));
    const done = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.done, done.kind);
    try std.testing.expect(fx.takeMsg() == null);
}

test "relational effects have a dedicated bounded slot family" {
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    for (0..effects_mod.max_db_effects) |index| {
        fx.dbQuery(.{ .key = 100 + index, .sql = "SELECT 1;", .on_result = Fx.dbMsg(.db) });
    }
    try std.testing.expectEqual(effects_mod.max_db_effects, fx.pendingDbCount());
    fx.dbQuery(.{ .key = 1_000, .sql = "SELECT 1;", .on_result = Fx.dbMsg(.db) });
    const rejected = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectDbOutcome.rejected, rejected.outcome);
}

test "relational pages and terminals cross the journal boundary verbatim" {
    const Capture = struct {
        var records: [4]effects_mod.EffectResultRecord = undefined;
        var payloads: [4][relational_store.max_page_bytes]u8 = undefined;
        var count: usize = 0;

        fn note(_: *anyopaque, record: effects_mod.EffectResultRecord) void {
            records[count] = record;
            @memcpy(payloads[count][0..record.payload.len], record.payload);
            records[count].payload = payloads[count][0..record.payload.len];
            count += 1;
        }
    };
    Capture.count = 0;
    var database = try relational_store.Database.openMemory(std.testing.allocator);
    defer database.deinit();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());
    var context: u8 = 0;
    fx.bindJournal(.{ .context = &context, .record_fn = Capture.note });

    fx.dbQuery(.{ .key = 40, .sql = "SELECT 7 AS answer;", .on_result = Fx.dbMsg(.db) });
    const page = try takeResult(&fx);
    try std.testing.expectEqual(@as(usize, 1), Capture.count);
    try std.testing.expectEqual(effects_mod.EffectResultKind.db, Capture.records[0].kind);
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.page, effects_mod.dbKindFromJournalCode(Capture.records[0].code).?);
    try std.testing.expectEqual(effects_mod.EffectDbOutcome.ok, effects_mod.dbOutcomeFromJournalCode(Capture.records[0].code).?);
    try std.testing.expectEqualSlices(u8, page.bytes, Capture.records[0].payload);
    const done = try takeResult(&fx);
    try std.testing.expectEqual(@as(usize, 2), Capture.count);
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.done, effects_mod.dbKindFromJournalCode(Capture.records[1].code).?);
    try std.testing.expectEqual(effects_mod.EffectDbOutcome.ok, effects_mod.dbOutcomeFromJournalCode(Capture.records[1].code).?);
    try std.testing.expectEqual(@as(usize, 0), done.bytes.len);
}

test "replay validates relational result shape before feeding it" {
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.dbQuery(.{ .key = 50, .sql = "SELECT 1;", .on_result = Fx.dbMsg(.db) });

    var oversized: [relational_store.max_page_bytes + 1]u8 = @splat(0);
    try std.testing.expectError(error.ReplayDamagedRecord, fx.feedDbResult(50, .page, .ok, &oversized));
    try std.testing.expectError(error.ReplayDamagedRecord, fx.feedDbResult(50, .page, .corrupt, ""));
    try std.testing.expectError(error.ReplayDamagedRecord, fx.feedDbResult(50, .done, .ok, "payload"));
    try std.testing.expectError(error.ReplayDamagedRecord, fx.feedDbResult(50, .exec, .ok, ""));
    const bad_tag_page = [_]u8{ 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 9 };
    try std.testing.expectError(error.ReplayDamagedRecord, fx.feedDbResult(50, .page, .ok, &bad_tag_page));

    const empty_page = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try fx.feedDbResult(50, .page, .ok, &empty_page);
    try fx.feedDbResult(50, .done, .ok, "");
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.page, (try takeResult(&fx)).kind);
    try std.testing.expectEqual(effects_mod.EffectDbResultKind.done, (try takeResult(&fx)).kind);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingDbCount());
}

test "live relational queries invalidate by table and coalesce until flush" {
    var database = try relational_store.Database.openMemory(std.testing.allocator);
    defer database.deinit();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    fx.dbExec(.{ .key = 60, .statements = &.{
        .{ .sql = "CREATE TABLE note(id INTEGER PRIMARY KEY) STRICT;" },
        .{ .sql = "CREATE TABLE unrelated(id INTEGER PRIMARY KEY) STRICT;" },
    }, .on_result = Fx.dbMsg(.db) });
    _ = try takeResult(&fx);
    fx.dbSubscribe(.{
        .key = 61,
        .sql = "SELECT id FROM note ORDER BY id;",
        .tables = &.{"note"},
        .on_result = Fx.dbMsg(.db),
    });
    const initial_page = try takeResult(&fx);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, initial_page.bytes[4..8], .little));
    _ = try takeResult(&fx);

    fx.dbExec(.{ .key = 62, .statements = &.{.{ .sql = "INSERT INTO note(id) VALUES(1);" }}, .on_result = Fx.dbMsg(.db) });
    fx.dbExec(.{ .key = 63, .statements = &.{.{ .sql = "INSERT INTO note(id) VALUES(2);" }}, .on_result = Fx.dbMsg(.db) });
    _ = try takeResult(&fx);
    _ = try takeResult(&fx);
    try std.testing.expect(fx.takeMsg() == null);
    fx.flushDbSubscriptions();
    const refreshed = try takeResult(&fx);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, refreshed.bytes[4..8], .little));
    _ = try takeResult(&fx);
    try std.testing.expect(fx.takeMsg() == null);

    fx.dbExec(.{ .key = 64, .statements = &.{.{ .sql = "INSERT INTO unrelated(id) VALUES(1);" }}, .on_result = Fx.dbMsg(.db) });
    _ = try takeResult(&fx);
    fx.flushDbSubscriptions();
    try std.testing.expect(fx.takeMsg() == null);
    fx.dbUnsubscribe(61);
}

test "replay keeps a live relational slot parked across repeated deliveries" {
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.dbSubscribe(.{ .key = 70, .sql = "SELECT 1 AS value;", .tables = &.{"note"}, .on_result = Fx.dbMsg(.db) });
    const page = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 'v', 'a', 'l', 'u', 'e' };
    try fx.feedDbResult(70, .page, .ok, &page);
    try fx.feedDbResult(70, .done, .ok, "");
    try fx.feedDbResult(70, .page, .ok, &page);
    try fx.feedDbResult(70, .done, .ok, "");
    for (0..4) |_| _ = try takeResult(&fx);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingDbCount());
    fx.dbUnsubscribe(70);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingDbCount());
}
