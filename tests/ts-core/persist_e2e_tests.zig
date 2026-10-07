//! Storage Tier 1 end-to-end coverage over a genuinely compiled TypeScript
//! core: live first boot, Cmd.persist after commit, atomic disk restore,
//! successful/failed migration, and replay's store-layer no-op.

const std = @import("std");
const native_sdk = @import("native_sdk");
const core = @import("ts_persist_core");

test {
    _ = @import("component_construction_e2e_tests.zig");
    _ = @import("component_composition_e2e_tests.zig");
    _ = @import("code_content_e2e_tests.zig");
    _ = @import("chart_content_e2e_tests.zig");
    _ = @import("markdown_content_e2e_tests.zig");
    _ = @import("widget_motion_e2e_tests.zig");
    _ = @import("widget_audits_e2e_tests.zig");
    _ = @import("widget_routing_e2e_tests.zig");
}

const Adapter = native_sdk.TsUiApp(core);
const Bridge = Adapter.Host;
const App = Adapter.App;

const canvas_label = "persist-canvas";
const views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Persistence",
    .width = 320,
    .height = 200,
    .views = &views,
}};
const scene: native_sdk.ShellConfig = .{ .windows = &windows };

fn compareLifecycle(request: []const u8) !void {
    const reference = @import("lifecycle_policy_reference");
    const frozen = try std.testing.allocator.dupe(u8, request);
    defer std.testing.allocator.free(frozen);
    var actual: [32]u8 = undefined;
    const expected = reference.plan(request);
    try std.testing.expectEqual(actual.len, core.nativeEffectPolicy(request, &actual));
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    try std.testing.expectEqualSlices(u8, frozen, request);
    const owned = actual;
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, &owned, &actual);
}

test "compiled app lifecycle plans preserve complete native decisions and exact word boundaries" {
    defer core.rt.frameReset();
    _ = core.initialModel();
    const borrowed = core.bootCommand();
    const saved = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(saved);
    var initial: [32]u8 = undefined;
    _ = core.nativeEffectPolicy(&.{ 18, 0, 0, 0, 0, 0 }, &initial);
    try std.testing.expectEqualSlices(u8, saved, borrowed);
    for (0..6) |event| for (0..2) |mapped| for (0..2) |pending| {
        try compareLifecycle(&.{ 18, 0, @intCast(event), @intCast(mapped), @intCast(pending), 0 });
    };
    for (0..16) |bits| try compareLifecycle(&.{ 18, 1, @intCast(bits & 1), @intCast((bits >> 1) & 1), @intCast((bits >> 2) & 1), @intCast((bits >> 3) & 1) });
    for (0..8) |bits| try compareLifecycle(&.{ 18, 2, @intCast(bits & 1), @intCast((bits >> 1) & 1), @intCast((bits >> 2) & 1) });
    const words = [_]u64{ 0, 1, 16 * 1024 * 1024 - 1, 16 * 1024 * 1024, 16 * 1024 * 1024 + 1, 0xffff_ffff, 0x1_0000_0000, 9_007_199_254_740_991, 9_007_199_254_740_993, std.math.maxInt(u64) };
    for (0..3) |source| for (0..2) |available| for (0..2) |success| for (0..7) |outcome| for (words) |length| {
        var request: [16]u8 = @splat(0);
        request[0..6].* = .{ 18, 3, @intCast(source), @intCast(available), @intCast(success), @intCast(outcome) };
        std.mem.writeInt(u64, request[8..16], length, .little);
        try compareLifecycle(&request);
    };
    for (0..7) |outcome| try compareLifecycle(&.{ 18, 4, @intCast(outcome) });
    for (0..3) |event| try compareLifecycle(&.{ 18, 5, @intCast(event) });
    for (0..2) |replay| for (words) |recorded| for (words) |live| for (words) |index| {
        var request: [32]u8 = @splat(0);
        request[0..3].* = .{ 18, 6, @intCast(replay) };
        std.mem.writeInt(u64, request[8..16], recorded, .little);
        std.mem.writeInt(u64, request[16..24], live, .little);
        std.mem.writeInt(u64, request[24..32], index, .little);
        try compareLifecycle(&request);
    };
    for (0..8) |operation| {
        const names: []const []const u8 = if (operation < 2) &.{ "", "core.persist", "core.persist.flush", "core.persist.flush.more", "core.persist\x00", "core.persist\xff", "service.read" } else &.{""};
        for (names) |name| {
            var request: [64]u8 = @splat(0);
            request[0..3].* = .{ 18, 7, @intCast(operation) };
            @memcpy(request[3..][0..name.len], name);
            try compareLifecycle(request[0 .. 3 + name.len]);
        }
    }
}

fn view(ui: *App.Ui, model: *const core.Model) App.Ui.Node {
    return ui.text(.{}, ui.fmt("value {d}", .{model.value}));
}

fn command(name: []const u8) ?core.Msg {
    if (std.mem.eql(u8, name, "persist.increment")) return .increment_and_persist;
    return null;
}

fn lifecycle(event: native_sdk.LifecycleEvent) ?core.Msg {
    if (event == .deactivate) return .increment_and_persist;
    return null;
}

fn options() App.Options {
    return .{
        .name = "persist-e2e",
        .scene = scene,
        .canvas_label = canvas_label,
        .view = view,
        .on_command = command,
        .on_lifecycle = lifecycle,
    };
}

const StoreHost = struct {
    coordinator: ?*native_sdk.persist_store.Coordinator = null,
    send_count: usize = 0,
    flush_count: usize = 0,
    send_count_at_flush: usize = 0,

    fn binding(self: *StoreHost) native_sdk.HostCallBinding {
        return .{ .context = self, .send_fn = send, .request_fn = request };
    }

    fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
        const self: *StoreHost = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, name, "core.persist.flush")) {
            self.flush_count += 1;
            self.send_count_at_flush = self.send_count;
            if (self.coordinator) |coordinator| coordinator.flush();
            return;
        }
        if (!std.mem.eql(u8, name, "core.persist")) return;
        self.send_count += 1;
        if (self.coordinator) |coordinator| {
            const outcome = coordinator.enqueue(payload);
            std.debug.assert(outcome == .ok);
        }
    }

    fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
        _ = context;
        _ = name;
        _ = key;
        _ = payload;
    }
};

const ReplayRestore = struct {
    outcome: native_sdk.persist_store.Outcome,
    bytes: []const u8,
};

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    state: *App,
    app: native_sdk.App,

    fn create(core_options: Adapter.CoreOptions, replay_restore: ?ReplayRestore) !*Harness {
        return createWithEnvironment(core_options, replay_restore, null);
    }

    fn createWithEnvironment(core_options: Adapter.CoreOptions, replay_restore: ?ReplayRestore, replay_env: ?[]const Adapter.EnvValue) !*Harness {
        const self = try std.testing.allocator.create(Harness);
        errdefer std.testing.allocator.destroy(self);
        self.harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
            .size = native_sdk.geometry.SizeF.init(320, 200),
        });
        errdefer self.harness.destroy(std.testing.allocator);
        self.harness.null_platform.gpu_surfaces = true;
        self.state = try std.testing.allocator.create(App);
        errdefer std.testing.allocator.destroy(self.state);
        self.state.* = Adapter.init(std.heap.page_allocator, core_options, options());
        if (replay_restore) |restore| {
            self.state.effects.armReplay();
            try self.state.effects.pushReplayPersist(restore.outcome, restore.bytes);
        }
        if (replay_env) |entries| {
            self.state.effects.armReplay();
            for (entries) |entry| try self.state.effects.pushReplayEnv(entry.msg, entry.value);
        }
        self.app = self.state.app();
        try self.harness.start(self.app);
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = native_sdk.geometry.SizeF.init(320, 200),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
        } });
        try std.testing.expect(self.state.installed);
        return self;
    }

    fn destroy(self: *Harness) void {
        self.state.deinit();
        std.testing.allocator.destroy(self.state);
        self.harness.destroy(std.testing.allocator);
        std.testing.allocator.destroy(self);
    }

    fn incrementAndPersist(self: *Harness) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .menu_command = .{
            .name = "persist.increment",
            .window_id = 1,
        } });
    }
};

fn routes() Adapter.PersistRoutes {
    return .{ .ok = "restored", .none = "fresh_boot", .err = "restore_failed" };
}

fn testDirPath(tmp: *const std.testing.TmpDir, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/persist", .{tmp.sub_path[0..]});
}

fn config(version: u64) native_sdk.persist_store.Config {
    return .{
        .schema_version = version,
        .model_fingerprint = core.sidecar_model_fingerprint,
        .snapshot_format = core.sidecar_snapshot_format,
    };
}

fn expectTaggedModelSnapshot(snapshot: []const u8, expected_fields: u32) !void {
    try std.testing.expect(snapshot.len >= 4);
    var at: usize = 0;
    try std.testing.expectEqual(expected_fields, std.mem.readInt(u32, snapshot[at..][0..4], .little));
    at += 4;
    var tag: u32 = 0;
    while (tag < expected_fields) : (tag += 1) {
        try std.testing.expect(at + 8 <= snapshot.len);
        try std.testing.expectEqual(tag, std.mem.readInt(u32, snapshot[at..][0..4], .little));
        at += 4;
        const len = std.mem.readInt(u32, snapshot[at..][0..4], .little);
        at += 4;
        try std.testing.expect(at + len <= snapshot.len);
        at += len;
    }
    try std.testing.expectEqual(snapshot.len, at);
}

test "Cmd.persist snapshots the committed model and restores it on the next boot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try testDirPath(&tmp, &path_buffer);
    const store = native_sdk.PersistStore.init(std.testing.io, std.heap.page_allocator, path, config(1));
    var coordinator: native_sdk.persist_store.Coordinator = undefined;
    try coordinator.start(store, 60_000);
    defer coordinator.deinit();
    var host: StoreHost = .{ .coordinator = &coordinator };

    const first = try Harness.create(.{ .persist = .{
        .binding = host.binding(),
        .routes = routes(),
        .restore = .{ .outcome = .none },
    } }, null);
    try std.testing.expectEqual(@as(i64, 2), Bridge.model().restoreState);
    try first.incrementAndPersist();
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().value);
    try expectTaggedModelSnapshot(core.persistenceSnapshot(), 4);
    coordinator.flush();
    first.destroy();
    try std.testing.expectEqual(@as(usize, 1), host.send_count);

    var restored = store.restore();
    defer restored.deinit(std.heap.page_allocator);
    try std.testing.expectEqual(native_sdk.persist_store.Outcome.ok, restored.outcome);
    const second = try Harness.create(.{ .persist = .{
        .binding = host.binding(),
        .routes = routes(),
        .restore = .{ .outcome = restored.outcome, .bytes = restored.bytes },
    } }, null);
    defer second.destroy();
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().value);
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().restoreState);
}

test "older snapshots migrate once and a thrown migration fails closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try testDirPath(&tmp, &path_buffer);

    Bridge.boot();
    const legacy_snapshot = core.persistenceSnapshot();
    const v1 = native_sdk.PersistStore.init(std.testing.io, std.heap.page_allocator, path, config(1));
    try std.testing.expectEqual(native_sdk.persist_store.Outcome.ok, v1.write(legacy_snapshot));

    const v2 = native_sdk.PersistStore.init(std.testing.io, std.heap.page_allocator, path, config(2));
    var needs_migration = v2.restore();
    defer needs_migration.deinit(std.heap.page_allocator);
    try std.testing.expectEqual(@as(?u64, 1), needs_migration.migration_from_version);
    var coordinator: native_sdk.persist_store.Coordinator = undefined;
    try coordinator.start(v2, 60_000);
    defer coordinator.deinit();
    var host: StoreHost = .{ .coordinator = &coordinator };
    const migrated = try Harness.create(.{ .persist = .{
        .binding = host.binding(),
        .routes = routes(),
        .restore = .{
            .outcome = needs_migration.outcome,
            .bytes = needs_migration.bytes,
            .migration_from_version = needs_migration.migration_from_version,
        },
    } }, null);
    try std.testing.expectEqual(@as(i64, 101), Bridge.model().value);
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().restoreState);
    coordinator.flush();
    migrated.destroy();

    var current = v2.restore();
    defer current.deinit(std.heap.page_allocator);
    try std.testing.expectEqual(native_sdk.persist_store.Outcome.ok, current.outcome);

    // Re-envelope that current body as schema 2, then ask a schema-3 core
    // to migrate it. The fixture deliberately throws for fromVersion 2.
    try std.Io.Dir.cwd().deleteTree(std.testing.io, path);
    try std.testing.expectEqual(native_sdk.persist_store.Outcome.ok, v2.write(current.bytes));
    const v3 = native_sdk.PersistStore.init(std.testing.io, std.heap.page_allocator, path, config(3));
    var rejected = v3.restore();
    defer rejected.deinit(std.heap.page_allocator);
    const failed = try Harness.create(.{ .persist = .{
        .binding = host.binding(),
        .routes = routes(),
        .restore = .{
            .outcome = rejected.outcome,
            .bytes = rejected.bytes,
            .migration_from_version = rejected.migration_from_version,
        },
    } }, null);
    defer failed.destroy();
    try std.testing.expectEqual(@as(i64, 0), Bridge.model().value);
    try std.testing.expectEqual(@as(i64, 3), Bridge.model().restoreState);
    try std.testing.expectEqualStrings("migrate_failed", Bridge.model().lastError);
}

test "an oversized migrated snapshot is rejected before it becomes the model" {
    const legacy = try std.testing.allocator.alloc(u8, native_sdk.max_persist_snapshot_bytes);
    defer std.testing.allocator.free(legacy);
    @memset(legacy, 'x');

    var host: StoreHost = .{};
    const rejected = try Harness.create(.{ .persist = .{
        .binding = host.binding(),
        .routes = routes(),
        .restore = .{
            .outcome = .migrate_failed,
            .bytes = legacy,
            .migration_from_version = 1,
        },
    } }, null);
    defer rejected.destroy();

    try std.testing.expectEqual(@as(i64, 0), Bridge.model().value);
    try std.testing.expectEqualStrings("initial", Bridge.model().label);
    try std.testing.expectEqual(@as(i64, 3), Bridge.model().restoreState);
    try std.testing.expectEqualStrings("rejected", Bridge.model().lastError);
    try std.testing.expectEqual(@as(usize, 0), host.send_count);
}

test "deactivation flushes after its mapped update can request persistence" {
    var host: StoreHost = .{};
    const running = try Harness.create(.{ .persist = .{
        .binding = host.binding(),
        .routes = routes(),
        .restore = .{ .outcome = .none },
    } }, null);
    defer running.destroy();

    try running.harness.runtime.dispatchPlatformEvent(running.app, .app_deactivated);

    try std.testing.expectEqual(@as(i64, 1), Bridge.model().value);
    try std.testing.expectEqual(@as(usize, 1), host.send_count);
    try std.testing.expectEqual(@as(usize, 1), host.flush_count);
    try std.testing.expectEqual(@as(usize, 1), host.send_count_at_flush);
}

test "replay restores journal bytes and Cmd.persist never reaches the live host" {
    Bridge.boot();
    const snapshot = try std.testing.allocator.dupe(u8, core.persistenceSnapshot());
    defer std.testing.allocator.free(snapshot);
    var host: StoreHost = .{};
    const replayed = try Harness.create(.{
        .persist = .{
            .binding = host.binding(),
            .routes = routes(),
            // Replay must ignore this live result and consume the queued record.
            .restore = .{ .outcome = .io_failed },
        },
    }, .{ .outcome = .ok, .bytes = snapshot });
    defer replayed.destroy();
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().restoreState);
    try replayed.incrementAndPersist();
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().value);
    try std.testing.expectEqual(@as(usize, 0), host.send_count);
}

test "a store worker failure is delivered through the configured err route" {
    var host: StoreHost = .{};
    var outcome_handle: native_sdk.ChannelHandle = .{};
    const running = try Harness.create(.{ .persist = .{
        .binding = host.binding(),
        .routes = routes(),
        .restore = .{ .outcome = .none },
        .outcome_handle = &outcome_handle,
    } }, null);
    defer running.destroy();

    try std.testing.expect(outcome_handle.live());
    try std.testing.expectEqual(
        native_sdk.ChannelHandle.PostResult.accepted,
        outcome_handle.post("io_failed"),
    );
    try running.harness.runtime.dispatchEvent(running.app, .effects_wake);

    try std.testing.expectEqual(@as(i64, 3), Bridge.model().restoreState);
    try std.testing.expectEqualStrings("io_failed", Bridge.model().lastError);
}

test "compiled launch environment keeps byte ownership and declaration order across live replay and old journals" {
    var first = [_]u8{ ':', 'A', 0, 255 };
    var second = [_]u8{ ':', 'B' };
    const values = [_]Adapter.EnvValue{
        .{ .msg = "launch_value", .value = &first },
        .{ .msg = "launch_value", .value = &second },
    };
    var host: StoreHost = .{};
    const live = try Harness.create(.{ .env_values = &values, .persist = .{ .binding = host.binding(), .routes = routes(), .restore = .{ .outcome = .none } } }, null);
    const expected = "initial:A\x00\xff:B";
    try std.testing.expectEqualStrings(expected, Bridge.model().label);
    try std.testing.expectEqual(@as(i64, 2), Bridge.model().restoreState);
    const snapshot = try std.testing.allocator.dupe(u8, core.persistenceSnapshot());
    defer std.testing.allocator.free(snapshot);
    first[1] = 'X';
    second[1] = 'Y';
    try std.testing.expectEqualStrings(expected, Bridge.model().label);
    live.destroy();
    const recorded = [_]Adapter.EnvValue{
        .{ .msg = "launch_value", .value = ":A\x00\xff" },
        .{ .msg = "launch_value", .value = ":B" },
    };
    const replayed = try Harness.createWithEnvironment(.{ .env_values = &values, .persist = .{ .binding = host.binding(), .routes = routes(), .restore = .{ .outcome = .io_failed, .migration_from_version = 2 } } }, .{ .outcome = .none, .bytes = "" }, &recorded);
    try std.testing.expectEqualStrings(expected, Bridge.model().label);
    try std.testing.expectEqualSlices(u8, snapshot, core.persistenceSnapshot());
    try std.testing.expectEqual(@as(usize, 0), replayed.state.effects.replay_env_len);
    replayed.destroy();
    const old = try Harness.createWithEnvironment(.{ .env_values = &values }, null, &.{});
    try std.testing.expectEqualStrings("initial:X\x00\xff:Y", Bridge.model().label);
    old.destroy();
    const fresh = try Harness.create(.{}, null);
    defer fresh.destroy();
    try std.testing.expectEqualStrings("initial", Bridge.model().label);
    try std.testing.expectEqual(@as(i64, 0), Bridge.model().restoreState);
}

test "compiled restore dispatches every complete outcome and stop flushes without a mapped message" {
    const outcomes = [_]native_sdk.persist_store.Outcome{ .none, .corrupt, .version_unknown, .migrate_failed, .io_failed, .rejected };
    for (outcomes) |outcome| {
        var host: StoreHost = .{};
        const running = try Harness.create(.{ .persist = .{ .binding = host.binding(), .routes = routes(), .restore = .{ .outcome = outcome } } }, null);
        defer running.destroy();
        try std.testing.expectEqual(@as(i64, if (outcome == .none) 2 else 3), Bridge.model().restoreState);
        try std.testing.expectEqualStrings(if (outcome == .none) "" else @tagName(outcome), Bridge.model().lastError);
        try running.harness.runtime.dispatchEvent(running.app, .{ .lifecycle = .stop });
        try std.testing.expectEqual(@as(usize, 1), host.flush_count);
    }
}

test "compiled dispatch coordination preserves complete plans and frame ownership" {
    const reference = @import("dispatch_policy_reference");
    defer core.rt.frameReset();
    _ = core.initialModel();
    const borrowed = core.bootCommand();
    const saved = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(saved);
    for (0..11) |stage| {
        const count: usize = if (stage == 9) 3 else 2;
        const second_count: usize = if (stage == 5 or stage >= 8) 2 else 1;
        for (0..count) |a| for (0..second_count) |b| {
            const request = [_]u8{ 19, @intCast(stage), @intCast(a), @intCast(b), 0, 0 };
            const frozen = request;
            const expected = reference.reference(@enumFromInt(stage), @intCast(a), @intCast(b));
            var actual: [16]u8 = undefined;
            try std.testing.expectEqual(actual.len, core.nativeEffectPolicy(&request, &actual));
            try std.testing.expectEqualSlices(u8, &expected, &actual);
            try std.testing.expectEqualSlices(u8, &frozen, &request);
            try std.testing.expectEqualSlices(u8, saved, borrowed);
            var unrelated: [16]u8 = undefined;
            _ = core.nativeEffectPolicy(&.{ 19, 1, 1, 0, 0, 0 }, &unrelated);
            try std.testing.expectEqualSlices(u8, &expected, &actual);
        };
    }
    var copied: [16]u8 = undefined;
    _ = core.nativeEffectPolicy(&.{ 19, 0, 0, 0, 0, 0 }, &copied);
    const owned = copied;
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, &owned, &copied);
}

fn compareReplay(record: native_sdk.runtime.EffectResultRecord) !void {
    const policy = native_sdk.runtime.replay_policy;
    const input = policy.request(record);
    const frozen = input;
    const expected = policy.plan(null, record);
    const actual = policy.plan(core.nativeEffectPolicy, record);
    try std.testing.expectEqual(expected.damage, actual.damage);
    try std.testing.expectEqual(expected.regenerates, actual.regenerates);
    try std.testing.expectEqual(expected.blob, actual.blob);
    try std.testing.expectEqualSlices(u8, &frozen, &input);
}

test "compiled replay admission preserves every damage predicate, provenance and exact word boundary" {
    defer core.rt.frameReset();
    _ = core.initialModel();
    const borrowed = core.bootCommand();
    const saved = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(saved);
    const Record = native_sdk.runtime.EffectResultRecord;
    const words = [_]u64{ 0, 1, 255, 256, 4096, 4097, 65536, 65537, 262144, 262145, 8388608, 8388609, 16777216, 16777217, 0xffffffff, 0x100000000, 9007199254740991, 9007199254740992, 9007199254740993, std.math.maxInt(u64) };
    for (1..19) |kind| {
        var record: Record = .{ .kind = @enumFromInt(kind), .key = std.math.maxInt(u64) };
        try compareReplay(record);
        inline for (@typeInfo(@FieldType(Record, "exit_reason")).@"enum".fields) |entry| {
            record.exit_reason = @enumFromInt(entry.value);
            try compareReplay(record);
        }
        record.exit_reason = (Record{ .kind = @enumFromInt(kind), .key = 0 }).exit_reason;
        inline for (@typeInfo(@FieldType(Record, "file_op")).@"enum".fields) |entry| {
            record.file_op = @enumFromInt(entry.value);
            try compareReplay(record);
        }
        record.file_op = (Record{ .kind = @enumFromInt(kind), .key = 0 }).file_op;
        inline for (@typeInfo(@FieldType(Record, "file_event")).@"enum".fields) |entry| {
            record.file_event = @enumFromInt(entry.value);
            try compareReplay(record);
        }
        record.file_event = (Record{ .kind = @enumFromInt(kind), .key = 0 }).file_event;
        inline for (@typeInfo(@FieldType(Record, "file_outcome")).@"enum".fields) |entry| {
            record.file_outcome = @enumFromInt(entry.value);
            try compareReplay(record);
        }
        record.file_outcome = (Record{ .kind = @enumFromInt(kind), .key = 0 }).file_outcome;
        inline for (@typeInfo(@FieldType(Record, "image_outcome")).@"enum".fields) |entry| {
            record.image_outcome = @enumFromInt(entry.value);
            try compareReplay(record);
        }
        record.image_outcome = (Record{ .kind = @enumFromInt(kind), .key = 0 }).image_outcome;
        inline for (@typeInfo(@FieldType(Record, "channel_kind")).@"enum".fields) |entry| {
            record.channel_kind = @enumFromInt(entry.value);
            try compareReplay(record);
        }
        record.channel_kind = (Record{ .kind = @enumFromInt(kind), .key = 0 }).channel_kind;
        inline for (@typeInfo(@FieldType(Record, "video_kind")).@"enum".fields) |entry| {
            record.video_kind = @enumFromInt(entry.value);
            try compareReplay(record);
        }
        record.video_kind = (Record{ .kind = @enumFromInt(kind), .key = 0 }).video_kind;
        inline for (@typeInfo(@FieldType(Record, "audio_kind")).@"enum".fields) |entry| {
            record.audio_kind = @enumFromInt(entry.value);
            try compareReplay(record);
        }
        record.audio_kind = (Record{ .kind = @enumFromInt(kind), .key = 0 }).audio_kind;
        inline for (@typeInfo(@FieldType(Record, "pty_kind")).@"enum".fields) |entry| {
            record.pty_kind = @enumFromInt(entry.value);
            try compareReplay(record);
        }
        record.pty_kind = (Record{ .kind = @enumFromInt(kind), .key = 0 }).pty_kind;
        inline for (@typeInfo(@FieldType(Record, "persist_outcome")).@"enum".fields) |entry| {
            record.persist_outcome = @enumFromInt(entry.value);
            try compareReplay(record);
        }
        record.persist_outcome = (Record{ .kind = @enumFromInt(kind), .key = 0 }).persist_outcome;
        inline for (@typeInfo(@FieldType(Record, "credentials_operation")).@"enum".fields) |entry| {
            record.credentials_operation = @enumFromInt(entry.value);
            try compareReplay(record);
        }
        record.credentials_operation = (Record{ .kind = @enumFromInt(kind), .key = 0 }).credentials_operation;
        inline for (@typeInfo(@FieldType(Record, "credentials_outcome")).@"enum".fields) |entry| {
            record.credentials_outcome = @enumFromInt(entry.value);
            try compareReplay(record);
        }
        record.credentials_outcome = (Record{ .kind = @enumFromInt(kind), .key = 0 }).credentials_outcome;
        inline for (@typeInfo(@FieldType(Record, "fetch_outcome")).@"enum".fields) |entry| {
            record.fetch_outcome = @enumFromInt(entry.value);
            try compareReplay(record);
        }
        record.fetch_outcome = (Record{ .kind = @enumFromInt(kind), .key = 0 }).fetch_outcome;
        inline for (@typeInfo(@FieldType(Record, "clipboard_outcome")).@"enum".fields) |entry| {
            record.clipboard_outcome = @enumFromInt(entry.value);
            try compareReplay(record);
        }
        record.clipboard_outcome = (Record{ .kind = @enumFromInt(kind), .key = 0 }).clipboard_outcome;
        for (words) |value| {
            record.file_blob_len = value;
            try compareReplay(record);
        }
        record.file_blob_len = 0;
        for (words) |value| {
            record.file_total = value;
            try compareReplay(record);
        }
        record.file_total = 0;
        for (words) |value| {
            record.file_mtime_ms = @bitCast(value);
            try compareReplay(record);
        }
        record.file_mtime_ms = 0;
        for (words) |value| {
            record.image_blob_len = value;
            try compareReplay(record);
        }
        record.image_blob_len = 0;
        for (words) |value| {
            record.image_width = value;
            try compareReplay(record);
        }
        record.image_width = 0;
        for (words) |value| {
            record.image_height = value;
            try compareReplay(record);
        }
        record.image_height = 0;
        for (words) |value| {
            record.video_position_ms = value;
            try compareReplay(record);
        }
        record.video_position_ms = 0;
        for (words) |value| {
            record.video_duration_ms = value;
            try compareReplay(record);
        }
        record.video_duration_ms = 0;
        for (words) |value| {
            record.video_width = value;
            try compareReplay(record);
        }
        record.video_width = 0;
        for (words) |value| {
            record.video_height = value;
            try compareReplay(record);
        }
        record.video_height = 0;
        for (words) |value| {
            record.video_token = value;
            try compareReplay(record);
        }
        record.video_token = 0;
        for (words) |value| {
            record.audio_position_ms = value;
            try compareReplay(record);
        }
        record.audio_position_ms = 0;
        for (words) |value| {
            record.audio_duration_ms = value;
            try compareReplay(record);
        }
        record.audio_duration_ms = 0;
        for (words) |value| {
            record.pty_blob_len = value;
            try compareReplay(record);
        }
        record.pty_blob_len = 0;
        for (words) |value| {
            record.persist_blob_len = value;
            try compareReplay(record);
        }
        record.persist_blob_len = 0;
        for (words) |value| {
            record.db_blob_len = value;
            try compareReplay(record);
        }
        record.db_blob_len = 0;
        for (words) |value| {
            record.credentials_secret_len = value;
            try compareReplay(record);
        }
        record.credentials_secret_len = 0;
        for ([_]i32{ std.math.minInt(i32), -257, -1, 0, 1, 255, 256, 257, 1536, 1792, 65536, std.math.maxInt(i32) }) |code| {
            record.code = code;
            try compareReplay(record);
        }
        record.code = 0;
        for ([_]i32{ std.math.minInt(i32), -1, 0, 1, 127, 128, std.math.maxInt(i32) }) |signal| {
            record.pty_signal = signal;
            try compareReplay(record);
        }
    }
    var seed: u64 = 0x92a1337;
    for (0..6000) |_| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        var record: Record = .{ .kind = @enumFromInt(1 + seed % 18), .key = seed };
        record.exit_reason = @enumFromInt((seed >> 0) % @typeInfo(@FieldType(Record, "exit_reason")).@"enum".fields.len);
        record.file_op = @enumFromInt((seed >> 3) % @typeInfo(@FieldType(Record, "file_op")).@"enum".fields.len);
        record.file_event = @enumFromInt((seed >> 6) % @typeInfo(@FieldType(Record, "file_event")).@"enum".fields.len);
        record.file_outcome = @enumFromInt((seed >> 9) % @typeInfo(@FieldType(Record, "file_outcome")).@"enum".fields.len);
        record.image_outcome = @enumFromInt((seed >> 12) % @typeInfo(@FieldType(Record, "image_outcome")).@"enum".fields.len);
        record.channel_kind = @enumFromInt((seed >> 15) % @typeInfo(@FieldType(Record, "channel_kind")).@"enum".fields.len);
        record.video_kind = @enumFromInt((seed >> 18) % @typeInfo(@FieldType(Record, "video_kind")).@"enum".fields.len);
        record.audio_kind = @enumFromInt((seed >> 21) % @typeInfo(@FieldType(Record, "audio_kind")).@"enum".fields.len);
        record.pty_kind = @enumFromInt((seed >> 24) % @typeInfo(@FieldType(Record, "pty_kind")).@"enum".fields.len);
        record.persist_outcome = @enumFromInt((seed >> 27) % @typeInfo(@FieldType(Record, "persist_outcome")).@"enum".fields.len);
        record.credentials_operation = @enumFromInt((seed >> 30) % @typeInfo(@FieldType(Record, "credentials_operation")).@"enum".fields.len);
        record.credentials_outcome = @enumFromInt((seed >> 33) % @typeInfo(@FieldType(Record, "credentials_outcome")).@"enum".fields.len);
        record.fetch_outcome = @enumFromInt((seed >> 36) % @typeInfo(@FieldType(Record, "fetch_outcome")).@"enum".fields.len);
        record.clipboard_outcome = @enumFromInt((seed >> 39) % @typeInfo(@FieldType(Record, "clipboard_outcome")).@"enum".fields.len);
        record.file_blob_len = words[@intCast((seed >> 0) % words.len)];
        record.file_total = words[@intCast((seed >> 3) % words.len)];
        record.file_mtime_ms = @bitCast(words[@intCast((seed >> 6) % words.len)]);
        record.image_blob_len = words[@intCast((seed >> 9) % words.len)];
        record.image_width = words[@intCast((seed >> 12) % words.len)];
        record.image_height = words[@intCast((seed >> 15) % words.len)];
        record.video_position_ms = words[@intCast((seed >> 18) % words.len)];
        record.video_duration_ms = words[@intCast((seed >> 21) % words.len)];
        record.video_width = words[@intCast((seed >> 24) % words.len)];
        record.video_height = words[@intCast((seed >> 27) % words.len)];
        record.video_token = words[@intCast((seed >> 30) % words.len)];
        record.audio_position_ms = words[@intCast((seed >> 33) % words.len)];
        record.audio_duration_ms = words[@intCast((seed >> 36) % words.len)];
        record.pty_blob_len = words[@intCast((seed >> 39) % words.len)];
        record.persist_blob_len = words[@intCast((seed >> 42) % words.len)];
        record.db_blob_len = words[@intCast((seed >> 45) % words.len)];
        record.credentials_secret_len = words[@intCast((seed >> 0) % words.len)];
        record.code = @bitCast(@as(u32, @truncate(seed)));
        record.pty_signal = @bitCast(@as(u32, @truncate(seed >> 32)));
        record.pty_dropped_writes = @truncate(seed);
        record.file_rejected_admission = seed & 1 != 0;
        record.file_exists = seed & 2 != 0;
        record.video_playing = seed & 4 != 0;
        record.video_buffering = seed & 8 != 0;
        record.truncated = seed & 16 != 0;
        record.credentials_salt[0] = @truncate(seed >> 5);
        record.credentials_digest[31] = @truncate(seed >> 13);
        const payload: [4097]u8 = @splat(0);
        record.payload = payload[0..@intCast(seed % 4098)];
        try compareReplay(record);
    }
    try std.testing.expectEqualSlices(u8, saved, borrowed);
    const input = native_sdk.runtime.replay_policy.request(.{ .kind = .timer, .key = 0 });
    var owned: [8]u8 = undefined;
    try std.testing.expectEqual(owned.len, core.nativeEffectPolicy(&input, &owned));
    const frozen = owned;
    var other: [8]u8 = undefined;
    const next = native_sdk.runtime.replay_policy.request(.{ .kind = .file, .key = 0 });
    _ = core.nativeEffectPolicy(&next, &other);
    try std.testing.expectEqualSlices(u8, &frozen, &owned);
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, &frozen, &owned);
}

const ReplayJournalBuffer = struct {
    bytes: std.ArrayList(u8) = .empty,
    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *ReplayJournalBuffer = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(std.testing.allocator, bytes);
    }
};
fn replayProbe(record: native_sdk.runtime.EffectResultRecord, expected: ?anyerror, feeds: usize) !void {
    const Probe = struct {
        var calls: usize = 0;
        fn control(_: *anyopaque, value: native_sdk.runtime.ReplayControl) anyerror!void {
            if (value == .feed) calls += 1;
        }
    };
    Probe.calls = 0;
    var buffer: ReplayJournalBuffer = .{};
    defer buffer.bytes.deinit(std.testing.allocator);
    const recorder = try std.heap.page_allocator.create(native_sdk.runtime.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = native_sdk.runtime.SessionRecorder.init(.{ .context = &buffer, .write_fn = ReplayJournalBuffer.write });
    recorder.begin(.{ .platform_name = "test", .app_name = "replay-admission", .window_chrome_source = .unavailable });
    recorder.recordEffect(record);
    recorder.finish();
    try std.testing.expect(!recorder.failed);
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var context: u8 = 0;
    const app: native_sdk.App = .{ .context = &context, .name = "probe", .replay_fn = Probe.control, .replay_policy = core.nativeEffectPolicy };
    const result = native_sdk.runtime.replaySession(&harness.runtime, app, buffer.bytes.items, .{ .verify = false, .require_same_platform = false });
    if (expected) |err| try std.testing.expectError(err, result) else {
        const report = try result;
        try std.testing.expectEqual(feeds, report.effects_fed);
    }
    try std.testing.expectEqual(feeds, Probe.calls);
}
test "compiled replay consumer gates damage before regeneration and preserves feed and blob ownership" {
    defer core.rt.frameReset();
    _ = core.initialModel();
    try replayProbe(.{ .kind = .file, .key = 1, .file_rejected_admission = true }, error.ReplayDamagedRecord, 0);
    try replayProbe(.{ .kind = .video, .key = 1, .video_kind = .rejected, .video_token = 1 }, error.ReplayDamagedRecord, 0);
    try replayProbe(.{ .kind = .channel, .key = 1, .channel_kind = .data, .exit_reason = .rejected }, error.ReplayDamagedRecord, 0);
    try replayProbe(.{ .kind = .pty, .key = 1, .pty_kind = .write, .truncated = true }, error.ReplayDamagedRecord, 0);
    try replayProbe(.{ .kind = .timer, .key = 1 }, null, 0);
    try replayProbe(.{ .kind = .file, .key = 1, .file_outcome = .rejected, .file_rejected_admission = true }, null, 0);
    try replayProbe(.{ .kind = .file, .key = 1, .file_outcome = .rejected }, null, 1);
    try replayProbe(.{ .kind = .channel, .key = 1, .channel_kind = .rejected }, null, 1);
    try replayProbe(.{ .kind = .image, .key = 1, .image_outcome = .loaded, .image_width = 1, .image_height = 1, .image_blob_len = 1 }, error.ReplayMissingBlob, 0);
    try replayProbe(.{ .kind = .persist, .key = 1, .persist_outcome = .ok, .persist_blob_len = 1 }, error.ReplayMissingBlob, 0);
}

test "compiled replay sequencing preserves complete header queue and verification plans" {
    const policy = native_sdk.runtime.replay_policy;
    defer core.rt.frameReset();
    _ = core.initialModel();
    inline for (@typeInfo(policy.Stage).@"enum".fields) |entry| {
        const stage: policy.Stage = @enumFromInt(entry.value);
        const count: usize = if (stage == .feed_error) 3 else 2;
        for (0..count) |a| for (0..2) |b| for (0..2) |c| {
            const expected = policy.coordinate(null, stage, @intCast(a), b != 0, c != 0);
            const actual = policy.coordinate(core.nativeEffectPolicy, stage, @intCast(a), b != 0, c != 0);
            try std.testing.expectEqual(expected, actual);
        };
    }
}

fn compareComponent(request: []const u8, expected: []const u8) !void {
    const frozen = try std.testing.allocator.dupe(u8, request);
    defer std.testing.allocator.free(frozen);
    var actual: [16]u8 = undefined;
    try std.testing.expectEqual(expected.len, core.nativeEffectPolicy(request, &actual));
    try std.testing.expectEqualSlices(u8, expected, actual[0..expected.len]);
    try std.testing.expectEqualSlices(u8, frozen, request);
    const copied = actual;
    var other: [16]u8 = undefined;
    _ = core.nativeEffectPolicy(&.{ 19, 0, 0, 0, 0, 0 }, &other);
    try std.testing.expectEqualSlices(u8, copied[0..expected.len], actual[0..expected.len]);
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, copied[0..expected.len], actual[0..expected.len]);
}

test "compiled component coordination preserves exact menu counts arenas recovery and scheduling" {
    const policy = native_sdk.runtime.component_policy;
    const words = [_]u64{ 0, 1, 0xffff_ffff, 0x1_0000_0000, 9_007_199_254_740_993, std.math.maxInt(u64) };
    for (0..16) |stage| for (0..8) |bits| for (words) |x| for (words) |y| {
        const a = bits & 1 != 0;
        const b = bits & 2 != 0;
        const c = bits & 4 != 0;
        const input = policy.request(@enumFromInt(stage), a, b, c, x, y);
        const expected = policy.reference(@enumFromInt(stage), a, b, c, x, y);
        try compareComponent(&input, &expected);
        const plan = policy.plan(core.nativeEffectPolicy, @enumFromInt(stage), a, b, c, x, y);
        try std.testing.expectEqualSlices(u8, &expected, &plan);
    };
}

test "compiled reach hysteresis preserves complete f32 axis and latch decisions" {
    const policy = native_sdk.runtime.component_policy;
    const canvas = native_sdk.canvas;
    const values = [_]f32{ -std.math.inf(f32), -100, -0.0, 0, 1, 99.99999, 100, 100.00001, 149.99998, 150, 150.00002, 300, 400, std.math.floatMax(f32), std.math.inf(f32), std.math.nan(f32) };
    for (0..2) |start| for (0..2) |present| for (0..4) |fired| for (0..3) |mode| for (values) |offset| for (values) |viewport| {
        const scroll: canvas.ScrollState = .{ .offset_y = offset, .viewport_extent_y = viewport, .content_extent_y = if (mode == 0) 400 else 0, .offset_x = offset, .viewport_extent_x = if (mode == 2) viewport else 100, .content_extent_x = 400 };
        const vf = fired & 1 != 0;
        const hf = fired & 2 != 0;
        const expected = policy.reachReference(start != 0, present != 0, scroll, vf, hf);
        const input = policy.reachRequest(start != 0, present != 0, scroll, vf, hf);
        const bytes = [_]u8{ @intFromBool(expected.horizontal), @intFromEnum(expected.action), 0, 0, 0, 0, 0, 0 };
        try compareComponent(&input, &bytes);
        const actual = policy.reach(core.nativeEffectPolicy, start != 0, present != 0, scroll, vf, hf);
        try std.testing.expectEqual(expected, actual);
    };
}

const appearance_canvas = native_sdk.canvas;
const appearance_style = appearance_canvas.WidgetAppearance;
fn expectAppearanceEqual(expected: anytype, actual: @TypeOf(expected)) !void {
    const T = @TypeOf(expected);
    switch (@typeInfo(T)) {
        .float => try std.testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(actual))),
        .optional => {
            try std.testing.expectEqual(expected != null, actual != null);
            if (expected) |value| try expectAppearanceEqual(value, actual.?);
        },
        .@"struct" => inline for (@typeInfo(T).@"struct".fields) |field| try expectAppearanceEqual(@field(expected, field.name), @field(actual, field.name)),
        .@"union" => {
            const tag = std.meta.activeTag(expected);
            try std.testing.expectEqual(tag, std.meta.activeTag(actual));
            inline for (@typeInfo(T).@"union".fields) |field| if (std.mem.eql(u8, field.name, @tagName(tag))) try expectAppearanceEqual(@field(expected, field.name), @field(actual, field.name));
        },
        else => try std.testing.expectEqual(expected, actual),
    }
}
fn compareAppearance(widget: appearance_canvas.Widget, tokens: appearance_canvas.DesignTokens) !void {
    var compiled = widget;
    compiled.appearance_policy = core.nativeWindowPolicy;
    const fallback = appearance_canvas.Color.rgba(0.17, 0.31, 0.73, 0.61);
    inline for (.{ "buttonControlVisualTokens", "textInputControlVisualTokens", "selectionControlVisualTokens", "surfaceControlVisualTokens", "componentControlVisualTokens", "listItemControlVisualTokens" }) |name| {
        try expectAppearanceEqual(@field(appearance_style, name)(widget, tokens), @field(appearance_style, name)(compiled, tokens));
    }
    try expectAppearanceEqual(appearance_style.selectControlVisualTokens(tokens), appearance_style.selectControlVisualTokensForWidget(compiled, tokens));
    inline for (.{ "buttonFillColor", "buttonTextColorForWidget", "buttonBorderFill", "buttonStrokeWidth", "buttonInDetachedGroup", "textEditingInkColor", "textSelectionFillColor", "textSelectionTextColor", "staticTextSelectionFillColor", "widgetFocusRingFill" }) |name| {
        try expectAppearanceEqual(@field(appearance_style, name)(widget, tokens), @field(appearance_style, name)(compiled, tokens));
    }
    inline for (.{ "widgetBackgroundColor", "widgetAccentColor", "widgetBorderColor" }) |name| try expectAppearanceEqual(@field(appearance_style, name)(widget, fallback), @field(appearance_style, name)(compiled, fallback));
    inline for (.{ "widgetForegroundColor", "widgetAccentForegroundColor" }) |name| try expectAppearanceEqual(@field(appearance_style, name)(widget, tokens, fallback), @field(appearance_style, name)(compiled, tokens, fallback));
    const visual = appearance_style.componentControlVisualTokens(widget, tokens);
    inline for (.{ "badgeBackgroundColor", "badgeBorderColor", "badgeTextColor", "badgeStrokeWidth" }) |name| try expectAppearanceEqual(@field(appearance_style, name)(widget, tokens, visual), @field(appearance_style, name)(compiled, tokens, visual));
    try expectAppearanceEqual(appearance_style.surfaceStateBackground(widget, visual, tokens), appearance_style.surfaceStateBackground(compiled, visual, tokens));
    try expectAppearanceEqual(appearance_style.textInputFill(widget, tokens, visual), appearance_style.textInputFill(compiled, tokens, visual));
    try expectAppearanceEqual(appearance_style.textInputBorderFill(widget, visual, fallback), appearance_style.textInputBorderFill(compiled, visual, fallback));
    try expectAppearanceEqual(appearance_style.listItemFillColor(widget, tokens, widget.state), appearance_style.listItemFillColor(compiled, tokens, widget.state));
    inline for (.{ "widgetRadius", "widgetSizedRadiusValue", "widgetStrokeWidth" }) |name| try expectAppearanceEqual(@field(appearance_style, name)(widget, 7), @field(appearance_style, name)(compiled, 7));
    inline for (.{ "controlRadius", "componentPillRadius", "controlStrokeWidth" }) |name| try expectAppearanceEqual(@field(appearance_style, name)(widget, visual, 7), @field(appearance_style, name)(compiled, visual, 7));
    try expectAppearanceEqual(appearance_style.buttonControlRadius(widget, visual, tokens), appearance_style.buttonControlRadius(compiled, visual, tokens));
    inline for (.{ "alertBackgroundColor", "alertBorderColor" }) |name| try expectAppearanceEqual(@field(appearance_style, name)(widget, visual, tokens), @field(appearance_style, name)(compiled, visual, tokens));
    for (0..3) |channel| try expectAppearanceEqual(appearance_style.selectionDisabledColor(widget, tokens, visual, fallback, @intCast(channel)), appearance_style.selectionDisabledColor(compiled, tokens, visual, fallback, @intCast(channel)));
    for (0..8) |flags| {
        try expectAppearanceEqual(appearance_style.buttonStateBackground(visual, flags & 1 != 0, flags & 2 != 0, fallback), appearance_style.buttonStateBackgroundForWidget(compiled, tokens, visual, flags & 1 != 0, flags & 2 != 0, fallback));
        try expectAppearanceEqual(appearance_style.controlStateBackground(visual, flags & 4 != 0, flags & 1 != 0, flags & 2 != 0, fallback), appearance_style.controlStateBackgroundForWidget(compiled, tokens, visual, flags & 4 != 0, flags & 1 != 0, flags & 2 != 0, fallback));
    }
    core.rt.frameReset();
}
test "compiled control appearance preserves complete native theme and state decisions" {
    inline for (.{ .house, .geist }) |pack| inline for (.{ .light, .dark }) |scheme| {
        const tokens = appearance_canvas.DesignTokens.theme(.{ .pack = pack, .color_scheme = scheme });
        for (std.enums.values(appearance_canvas.WidgetKind)) |kind| for (std.enums.values(appearance_canvas.WidgetVariant)) |variant| for (0..16) |flags| {
            const widget = appearance_canvas.Widget{ .kind = kind, .variant = variant, .size = @enumFromInt(flags % 6), .style = .{ .quiet_hover = flags % 3 == 0 }, .state = .{ .disabled = flags & 1 != 0, .pressed = flags & 2 != 0, .selected = flags & 4 != 0, .hovered = flags & 8 != 0 } };
            try compareAppearance(widget, tokens);
        };
    };
}

test "compiled appearance preserves authored optional values and borrowed ABI ownership" {
    _ = core.initialModel();
    const borrowed = core.bootCommand();
    const saved = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(saved);
    const bits = [_]u32{ 0, 0x80000000, 0x7fc00037, 0x7f800000, 0xff800000, 0x3eaaaaab };
    for (bits) |word| {
        const value: f32 = @bitCast(word);
        var widget = appearance_canvas.Widget{ .kind = .button, .style = .{ .radius = value, .stroke_width = value, .background = .{ .r = value, .g = value, .b = value, .a = value } } };
        var compiled = widget;
        compiled.appearance_policy = core.nativeWindowPolicy;
        try expectAppearanceEqual(appearance_style.widgetRadius(widget, 7), appearance_style.widgetRadius(compiled, 7));
        try expectAppearanceEqual(appearance_style.widgetStrokeWidth(widget, 7), appearance_style.widgetStrokeWidth(compiled, 7));
        try expectAppearanceEqual(appearance_style.widgetBackgroundColor(widget, .{}), appearance_style.widgetBackgroundColor(compiled, .{}));
        widget.style.radius = null;
        compiled.style.radius = null;
        try expectAppearanceEqual(appearance_style.widgetSizedRadiusValue(widget, value), appearance_style.widgetSizedRadiusValue(compiled, value));
    }
    try std.testing.expectEqualSlices(u8, saved, borrowed);
    core.rt.frameReset();
}

test "compiled appearance preserves sparse and complete custom visual registers" {
    const color_names = .{ "background", "hover_background", "active_background", "pressed_background", "disabled_background", "disabled_foreground", "foreground", "active_foreground", "border" };
    for (0..12) |mask_case| {
        var tokens = appearance_canvas.DesignTokens{};
        inline for (@typeInfo(@TypeOf(tokens.controls)).@"struct".fields, 0..) |field, table_index| {
            if (field.type == appearance_canvas.ControlVisualTokens) {
                var visual: appearance_canvas.ControlVisualTokens = .{};
                inline for (color_names, 0..) |name, i| {
                    if (mask_case == 11 or mask_case == i) @field(visual, name) = appearance_canvas.Color.rgba(@as(f32, @floatFromInt(table_index + 1)) / 64, @as(f32, @floatFromInt(i + 1)) / 16, 0.37, if (i % 3 == 0) 0 else 0.71);
                }
                if (mask_case == 9 or mask_case == 11) visual.radius = 0;
                if (mask_case == 10 or mask_case == 11) visual.stroke_width = 0;
                @field(tokens.controls, field.name) = visual;
            }
        }
        tokens.controls.button_group_style = .detached;
        for (std.enums.values(appearance_canvas.WidgetKind)) |kind| for (std.enums.values(appearance_canvas.WidgetVariant)) |variant| for (0..16) |flags| {
            const widget = appearance_canvas.Widget{ .kind = kind, .variant = variant, .group_segment = if (flags % 2 == 0) .none else .middle, .size = @enumFromInt(flags % 6), .state = .{ .disabled = flags & 1 != 0, .pressed = flags & 2 != 0, .selected = flags & 4 != 0, .hovered = flags & 8 != 0 }, .style = .{ .background = if (flags % 5 == 0) .{ .a = 0 } else null, .foreground = if (flags % 3 == 0) .{ .r = 0.23, .g = 0.37, .b = 0.51, .a = 0.73 } else null } };
            try compareAppearance(widget, tokens);
        };
    }
}

test "compiled appearance drives complete native draw commands" {
    const canvas = appearance_canvas;
    const geometry = native_sdk.geometry;
    inline for (.{ .house, .geist }) |pack| inline for (.{ .light, .dark }) |scheme| {
        const tokens = canvas.DesignTokens.theme(.{ .pack = pack, .color_scheme = scheme });
        for (std.enums.values(canvas.WidgetKind)) |kind| for (std.enums.values(canvas.WidgetVariant)) |variant| for (0..16) |flags| {
            const widget = canvas.Widget{ .id = 42, .kind = kind, .variant = variant, .frame = geometry.RectF.init(0, 0, 240, 80), .text = "Control", .value = 0.5, .state = .{ .disabled = flags & 1 != 0, .pressed = flags & 2 != 0, .selected = flags & 4 != 0, .hovered = flags & 8 != 0, .focused = flags % 3 == 0 } };
            var compiled = widget;
            compiled.appearance_policy = core.nativeWindowPolicy;
            var native_commands: [256]canvas.CanvasCommand = undefined;
            var compiled_commands: [256]canvas.CanvasCommand = undefined;
            var reference = canvas.Builder.init(&native_commands);
            var actual = canvas.Builder.init(&compiled_commands);
            try canvas.emitWidgetTree(&reference, widget, tokens);
            try canvas.emitWidgetTree(&actual, compiled, tokens);
            try std.testing.expectEqualDeep(reference.displayList().commands, actual.displayList().commands);
            var changes: [256]canvas.DiffChange = undefined;
            try std.testing.expectEqual(@as(usize, 0), (try canvas.DisplayList.diff(reference.displayList(), actual.displayList(), &changes)).len);
            core.rt.frameReset();
        };
    };
}

test "compiled alpha arithmetic matches native exceptional and signed zero inputs" {
    const bits = [_]u32{ 0, 0x80000000, 0x7fc00037, 0x7f800000, 0xff800000, 0x3eaaaaab, 0x3f800001, 0xbeaaaaab };
    for (bits) |word| for (bits) |alpha_word| {
        const alpha: f32 = @bitCast(alpha_word);
        var tokens = appearance_canvas.DesignTokens{};
        tokens.states.disabled_alpha = alpha;
        tokens.states.selection_wash_alpha = alpha;
        const widget = appearance_canvas.Widget{ .kind = .button, .state = .{ .disabled = true }, .style = .{ .foreground = .{ .r = 0.17, .g = 0.31, .b = 0.73, .a = @bitCast(word) }, .accent = .{ .r = 0.17, .g = 0.31, .b = 0.73, .a = @bitCast(word) } } };
        var compiled = widget;
        compiled.appearance_policy = core.nativeWindowPolicy;
        try expectAppearanceEqual(appearance_style.widgetForegroundColor(widget, tokens, .{}), appearance_style.widgetForegroundColor(compiled, tokens, .{}));
        try expectAppearanceEqual(appearance_style.staticTextSelectionFillColor(widget, tokens), appearance_style.staticTextSelectionFillColor(compiled, tokens));
        core.rt.frameReset();
    };
}
