//! Storage Tier 1 end-to-end coverage over a genuinely compiled TypeScript
//! core: live first boot, Cmd.persist after commit, atomic disk restore,
//! successful/failed migration, and replay's store-layer no-op.

const std = @import("std");
const native_sdk = @import("native_sdk");
const core = @import("ts_persist_core");

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
