//! Engine-owned model snapshot storage.
//!
//! The app core supplies only its canonical committed-model bytes. This
//! module owns placement beneath the already-resolved app data directory,
//! envelopes those bytes with version/shape metadata, and installs snapshots
//! atomically. The previous valid primary is retained as one backup
//! generation; restore consults it only when the primary is missing or
//! structurally corrupt.

const std = @import("std");

pub const max_snapshot_bytes: usize = 16 * 1024 * 1024;
pub const store_format: u32 = 1;
pub const snapshot_name = "snapshot.nsd";
pub const backup_name = "snapshot.nsd.bak";

const magic = "NSDPST01".*;
const checksum_len = 16;
const header_len = magic.len + 4 + 4 + 8 + 8 + 8 + checksum_len;

pub const Outcome = enum(u8) {
    ok,
    none,
    corrupt,
    version_unknown,
    migrate_failed,
    io_failed,
    rejected,
};

pub const Config = struct {
    schema_version: u64,
    model_fingerprint: u64,
    snapshot_format: u32,
};

pub const RestoreResult = struct {
    outcome: Outcome,
    bytes: []u8 = &.{},
    used_backup: bool = false,
    migration_from_version: ?u64 = null,

    pub fn deinit(self: *RestoreResult, allocator: std.mem.Allocator) void {
        if (self.bytes.len > 0) allocator.free(self.bytes);
        self.* = .{ .outcome = .none };
    }
};

pub const Store = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    config: Config,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8, config: Config) Store {
        return .{ .io = io, .allocator = allocator, .data_dir = data_dir, .config = config };
    }

    pub fn write(self: Store, snapshot: []const u8) Outcome {
        if (snapshot.len > max_snapshot_bytes) return .rejected;
        if (self.data_dir.len == 0) return .io_failed;

        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(self.io, self.data_dir) catch return .io_failed;

        var primary_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const primary_path = joinPath(&primary_buffer, self.data_dir, snapshot_name) orelse return .io_failed;
        var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const backup_path = joinPath(&backup_buffer, self.data_dir, backup_name) orelse return .io_failed;

        // An older binary must not displace either generation written by a
        // newer schema. Checking the backup separately matters when the
        // future primary is torn: repeated rollback writes must not erase the
        // last recoverable future generation.
        if (cwd.readFileAlloc(self.io, backup_path, self.allocator, .limited(header_len + max_snapshot_bytes))) |previous| {
            defer self.allocator.free(previous);
            if (decodeEnvelope(previous, null) == .valid and envelopeSchemaVersion(previous) > self.config.schema_version) {
                return .version_unknown;
            }
        } else |_| {}

        // Preserve only a structurally sound primary. A corrupt primary must
        // never replace the last known-good backup.
        if (cwd.readFileAlloc(self.io, primary_path, self.allocator, .limited(header_len + max_snapshot_bytes))) |previous| {
            defer self.allocator.free(previous);
            if (decodeEnvelope(previous, null) == .valid) {
                if (envelopeSchemaVersion(previous) > self.config.schema_version) return .version_unknown;
                atomicWrite(self.io, cwd, backup_path, previous) catch return .io_failed;
            }
        } else |_| {}

        const envelope = self.allocator.alloc(u8, header_len + snapshot.len) catch return .io_failed;
        defer self.allocator.free(envelope);
        encodeEnvelope(envelope, self.config, snapshot);
        atomicWrite(self.io, cwd, primary_path, envelope) catch return .io_failed;
        return .ok;
    }

    pub fn restore(self: Store) RestoreResult {
        if (self.data_dir.len == 0) return .{ .outcome = .io_failed };
        var primary_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const primary_path = joinPath(&primary_buffer, self.data_dir, snapshot_name) orelse return .{ .outcome = .io_failed };
        var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const backup_path = joinPath(&backup_buffer, self.data_dir, backup_name) orelse return .{ .outcome = .io_failed };

        const primary = self.readOne(primary_path);
        switch (primary.outcome) {
            .ok, .version_unknown, .migrate_failed => return primary,
            .none, .corrupt, .io_failed => {},
            .rejected => unreachable,
        }

        var backup = self.readOne(backup_path);
        switch (backup.outcome) {
            .ok => {
                backup.used_backup = true;
                return backup;
            },
            .version_unknown, .migrate_failed => return backup,
            .none => return if (primary.outcome == .none)
                .{ .outcome = .none }
            else
                .{ .outcome = primary.outcome },
            .corrupt => return .{ .outcome = if (primary.outcome == .none) .corrupt else primary.outcome },
            .io_failed => return .{ .outcome = if (primary.outcome == .none) .io_failed else primary.outcome },
            .rejected => unreachable,
        }
    }

    fn readOne(self: Store, path: []const u8) RestoreResult {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(header_len + max_snapshot_bytes),
        ) catch |err| return .{ .outcome = if (err == error.FileNotFound) .none else .io_failed };
        defer self.allocator.free(bytes);

        const decoded = decodeEnvelope(bytes, self.config);
        switch (decoded) {
            .valid => |body| {
                const copy = self.allocator.dupe(u8, body) catch return .{ .outcome = .io_failed };
                return .{ .outcome = .ok, .bytes = copy };
            },
            .corrupt => return .{ .outcome = .corrupt },
            .future_version => return .{ .outcome = .version_unknown },
            .migration_required => |old| {
                const copy = self.allocator.dupe(u8, old.body) catch return .{ .outcome = .io_failed };
                return .{ .outcome = .migrate_failed, .bytes = copy, .migration_from_version = old.version };
            },
        }
    }
};

/// Optional worker-to-host terminal hook. Only failed write outcomes are
/// reported: successful fire-and-forget persists stay silent, while every
/// failure crosses the host's effect boundary as a routed Msg.
pub const OutcomeHandler = struct {
    context: *anyopaque,
    report_fn: *const fn (context: *anyopaque, outcome: Outcome) void,
};

/// Host-side trailing-edge persistence. Command dispatch only copies the
/// latest committed snapshot into this coordinator; filesystem work stays off
/// the update/event-loop thread. A reissue replaces the pending bytes, an
/// issue during a write becomes the next generation, and `deinit` force-flushes
/// the tail before returning.
///
/// `allocator` must be safe to use from the coordinator worker. Shipping
/// runners use the page allocator.
pub const Coordinator = struct {
    store: Store,
    debounce_ms: u32,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    pending: ?[]u8 = null,
    generation: u64 = 0,
    writing: bool = false,
    flush_requested: bool = false,
    stopping: bool = false,
    thread: ?std.Thread = null,
    outcome_handler: ?OutcomeHandler = null,

    pub fn start(self: *Coordinator, store: Store, debounce_ms: u32) !void {
        try self.startWithOutcomeHandler(store, debounce_ms, null);
    }

    pub fn startWithOutcomeHandler(self: *Coordinator, store: Store, debounce_ms: u32, outcome_handler: ?OutcomeHandler) !void {
        self.* = .{ .store = store, .debounce_ms = debounce_ms, .outcome_handler = outcome_handler };
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    /// Queue the newest committed-model bytes. Rejections are synchronous so
    /// an over-bound snapshot is never silently dropped; I/O outcomes are
    /// reported by the worker's closed enum through `OutcomeHandler`.
    pub fn enqueue(self: *Coordinator, snapshot: []const u8) Outcome {
        if (snapshot.len > max_snapshot_bytes) return .rejected;
        const copy = self.store.allocator.dupe(u8, snapshot) catch return .io_failed;
        self.mutex.lockUncancelable(self.store.io);
        defer self.mutex.unlock(self.store.io);
        if (self.stopping) {
            self.store.allocator.free(copy);
            return .rejected;
        }
        if (self.pending) |previous| self.store.allocator.free(previous);
        self.pending = copy;
        self.generation +%= 1;
        self.condition.signal(self.store.io);
        return .ok;
    }

    pub fn deinit(self: *Coordinator) void {
        self.mutex.lockUncancelable(self.store.io);
        self.stopping = true;
        self.condition.signal(self.store.io);
        self.mutex.unlock(self.store.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    /// Force the current tail to stable storage. Used by platform
    /// deactivate/background and stop hooks so the debounce window cannot
    /// lose the last committed update.
    pub fn flush(self: *Coordinator) void {
        self.mutex.lockUncancelable(self.store.io);
        self.flush_requested = true;
        self.condition.signal(self.store.io);
        while ((self.pending != null or self.writing) and !self.stopping) {
            self.condition.waitUncancelable(self.store.io, &self.mutex);
        }
        self.flush_requested = false;
        self.mutex.unlock(self.store.io);
    }

    fn workerMain(self: *Coordinator) void {
        while (true) {
            self.mutex.lockUncancelable(self.store.io);
            while (self.pending == null and !self.stopping) {
                self.condition.waitUncancelable(self.store.io, &self.mutex);
            }
            if (self.stopping) {
                const tail = self.pending;
                self.pending = null;
                self.mutex.unlock(self.store.io);
                if (tail) |bytes| {
                    const outcome = self.store.write(bytes);
                    self.store.allocator.free(bytes);
                    self.report(outcome);
                }
                return;
            }
            var observed_generation = self.generation;
            const force = self.flush_requested;
            self.mutex.unlock(self.store.io);

            // Io.Condition has no timed wait. Polling in short, bounded sleeps
            // keeps shutdown responsive while preserving a true trailing edge:
            // every replacement restarts the full debounce window.
            var waited_ms: u32 = 0;
            while (!force and waited_ms < self.debounce_ms) {
                const slice_ms = @min(self.debounce_ms - waited_ms, 10);
                std.Io.sleep(self.store.io, std.Io.Duration.fromMilliseconds(slice_ms), .awake) catch {};
                waited_ms += slice_ms;
                self.mutex.lockUncancelable(self.store.io);
                if (self.stopping) {
                    self.mutex.unlock(self.store.io);
                    break;
                }
                if (self.flush_requested) {
                    self.mutex.unlock(self.store.io);
                    break;
                }
                if (self.generation != observed_generation) {
                    observed_generation = self.generation;
                    waited_ms = 0;
                }
                self.mutex.unlock(self.store.io);
            }

            self.mutex.lockUncancelable(self.store.io);
            if (self.stopping) {
                self.mutex.unlock(self.store.io);
                continue;
            }
            const bytes = self.pending.?;
            self.pending = null;
            self.writing = true;
            self.mutex.unlock(self.store.io);
            const outcome = self.store.write(bytes);
            self.store.allocator.free(bytes);
            self.report(outcome);
            self.mutex.lockUncancelable(self.store.io);
            self.writing = false;
            if (self.pending == null) {
                self.flush_requested = false;
                self.condition.broadcast(self.store.io);
            }
            self.mutex.unlock(self.store.io);
            // An enqueue during `write` left `pending` populated; the next
            // iteration gives it its own trailing-edge window.
        }
    }

    fn report(self: *Coordinator, outcome: Outcome) void {
        if (outcome == .ok) return;
        if (self.outcome_handler) |handler| {
            handler.report_fn(handler.context, outcome);
        } else {
            std.log.err("model persistence write failed: {s}", .{@tagName(outcome)});
        }
    }
};

const Decoded = union(enum) {
    valid: []const u8,
    corrupt,
    future_version,
    migration_required: struct { body: []const u8, version: u64 },
};

fn decodeEnvelope(bytes: []const u8, expected: ?Config) Decoded {
    if (bytes.len < header_len) return .corrupt;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return .corrupt;
    var at: usize = magic.len;
    const format = takeInt(u32, bytes, &at);
    const snapshot_format = takeInt(u32, bytes, &at);
    const schema_version = takeInt(u64, bytes, &at);
    const model_fingerprint = takeInt(u64, bytes, &at);
    const body_len_u64 = takeInt(u64, bytes, &at);
    const checksum_at = at;
    const checksum = bytes[checksum_at .. checksum_at + checksum_len];
    at += checksum_len;
    if (format != store_format or body_len_u64 > max_snapshot_bytes) return .corrupt;
    const body_len = std.math.cast(usize, body_len_u64) orelse return .corrupt;
    if (bytes.len != header_len + body_len) return .corrupt;
    const body = bytes[at..];
    const actual = checksumEnvelope(bytes[0..checksum_at], body);
    if (!std.crypto.timing_safe.eql([checksum_len]u8, checksum[0..checksum_len].*, actual)) return .corrupt;

    if (expected) |config| {
        if (schema_version > config.schema_version) return .future_version;
        if (snapshot_format != config.snapshot_format) return .corrupt;
        if (schema_version < config.schema_version) return .{ .migration_required = .{ .body = body, .version = schema_version } };
        if (model_fingerprint != config.model_fingerprint) return .corrupt;
    }
    return .{ .valid = body };
}

fn encodeEnvelope(out: []u8, config: Config, snapshot: []const u8) void {
    std.debug.assert(out.len == header_len + snapshot.len);
    @memcpy(out[0..magic.len], &magic);
    var at: usize = magic.len;
    putInt(u32, out, &at, store_format);
    putInt(u32, out, &at, config.snapshot_format);
    putInt(u64, out, &at, config.schema_version);
    putInt(u64, out, &at, config.model_fingerprint);
    putInt(u64, out, &at, snapshot.len);
    const checksum_at = at;
    at += checksum_len;
    @memcpy(out[at..], snapshot);
    const checksum = checksumEnvelope(out[0..checksum_at], snapshot);
    @memcpy(out[checksum_at .. checksum_at + checksum_len], &checksum);
}

fn checksumEnvelope(header: []const u8, body: []const u8) [checksum_len]u8 {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(header);
    hasher.update(body);
    hasher.final(&digest);
    return digest[0..checksum_len].*;
}

fn putInt(comptime T: type, out: []u8, at: *usize, value: T) void {
    const size = @sizeOf(T);
    std.mem.writeInt(T, out[at.*..][0..size], value, .little);
    at.* += size;
}

fn takeInt(comptime T: type, bytes: []const u8, at: *usize) T {
    const size = @sizeOf(T);
    const value = std.mem.readInt(T, bytes[at.*..][0..size], .little);
    at.* += size;
    return value;
}

/// Read the schema field from an envelope already accepted by the structural
/// `decodeEnvelope(bytes, null)` check.
fn envelopeSchemaVersion(bytes: []const u8) u64 {
    const at = magic.len + @sizeOf(u32) + @sizeOf(u32);
    return std.mem.readInt(u64, bytes[at..][0..@sizeOf(u64)], .little);
}

fn joinPath(buffer: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{ dir, std.fs.path.sep_str, name }) catch null;
}

fn atomicWrite(io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, bytes, 0);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

fn testDirPath(tmp: *const std.testing.TmpDir, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/persist", .{tmp.sub_path[0..]});
}

test "snapshot store round-trips metadata and bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try testDirPath(&tmp, &path_buffer);
    const config: Config = .{ .schema_version = 3, .model_fingerprint = 0x1234, .snapshot_format = 1 };
    const store = Store.init(std.testing.io, std.testing.allocator, path, config);

    try std.testing.expectEqual(Outcome.none, store.restore().outcome);
    try std.testing.expectEqual(Outcome.ok, store.write("canonical model bytes"));
    var restored = store.restore();
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.ok, restored.outcome);
    try std.testing.expectEqualStrings("canonical model bytes", restored.bytes);
    try std.testing.expect(!restored.used_backup);
}

test "snapshot store falls back to the previous generation when primary is torn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try testDirPath(&tmp, &path_buffer);
    const config: Config = .{ .schema_version = 1, .model_fingerprint = 7, .snapshot_format = 1 };
    const store = Store.init(std.testing.io, std.testing.allocator, path, config);

    try std.testing.expectEqual(Outcome.ok, store.write("first"));
    try std.testing.expectEqual(Outcome.ok, store.write("second"));
    var primary_buffer: [512]u8 = undefined;
    const primary = joinPath(&primary_buffer, path, snapshot_name).?;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = primary, .data = "torn" });

    var restored = store.restore();
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.ok, restored.outcome);
    try std.testing.expectEqualStrings("first", restored.bytes);
    try std.testing.expect(restored.used_backup);
}

test "snapshot store falls back when primary metadata is corrupted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try testDirPath(&tmp, &path_buffer);
    const config: Config = .{ .schema_version = 1, .model_fingerprint = 7, .snapshot_format = 1 };
    const store = Store.init(std.testing.io, std.testing.allocator, path, config);

    try std.testing.expectEqual(Outcome.ok, store.write("first"));
    try std.testing.expectEqual(Outcome.ok, store.write("second"));
    var primary_buffer: [512]u8 = undefined;
    const primary = joinPath(&primary_buffer, path, snapshot_name).?;
    const envelope = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        primary,
        std.testing.allocator,
        .limited(header_len + max_snapshot_bytes),
    );
    defer std.testing.allocator.free(envelope);
    envelope[magic.len + @sizeOf(u32) + @sizeOf(u32)] ^= 0x80;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = primary, .data = envelope });

    var restored = store.restore();
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.ok, restored.outcome);
    try std.testing.expectEqualStrings("first", restored.bytes);
    try std.testing.expect(restored.used_backup);
}

test "snapshot store does not mistake a corrupt orphaned backup for first boot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try testDirPath(&tmp, &path_buffer);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, path);
    var backup_buffer: [512]u8 = undefined;
    const backup = joinPath(&backup_buffer, path, backup_name).?;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = backup, .data = "torn" });

    const store = Store.init(std.testing.io, std.testing.allocator, path, .{
        .schema_version = 1,
        .model_fingerprint = 7,
        .snapshot_format = 1,
    });
    try std.testing.expectEqual(Outcome.corrupt, store.restore().outcome);
}

test "snapshot store keeps the live generation when interrupted before atomic replace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try testDirPath(&tmp, &path_buffer);
    const config: Config = .{ .schema_version = 1, .model_fingerprint = 7, .snapshot_format = 1 };
    const store = Store.init(std.testing.io, std.testing.allocator, path, config);
    try std.testing.expectEqual(Outcome.ok, store.write("stable"));

    // Exercise the exact primitive atomicWrite uses, but stop after the
    // temporary file is synced and before replace. Deinit removes the
    // abandoned same-directory temporary file; the installed generation is
    // untouched, which is the process-kill boundary the store relies on.
    var primary_buffer: [512]u8 = undefined;
    const primary = joinPath(&primary_buffer, path, snapshot_name).?;
    var interrupted = try std.Io.Dir.cwd().createFileAtomic(std.testing.io, primary, .{ .make_path = true, .replace = true });
    try interrupted.file.writePositionalAll(std.testing.io, "not installed", 0);
    try interrupted.file.sync(std.testing.io);
    interrupted.deinit(std.testing.io);

    var restored = store.restore();
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.ok, restored.outcome);
    try std.testing.expectEqualStrings("stable", restored.bytes);
    try std.testing.expect(!restored.used_backup);
}

test "snapshot store closes version and shape mismatches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try testDirPath(&tmp, &path_buffer);
    const old = Store.init(std.testing.io, std.testing.allocator, path, .{ .schema_version = 2, .model_fingerprint = 9, .snapshot_format = 1 });
    try std.testing.expectEqual(Outcome.ok, old.write("model"));

    const newer = Store.init(std.testing.io, std.testing.allocator, path, .{ .schema_version = 3, .model_fingerprint = 10, .snapshot_format = 1 });
    var migration = newer.restore();
    defer migration.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.migrate_failed, migration.outcome);
    try std.testing.expectEqual(@as(?u64, 2), migration.migration_from_version);
    try std.testing.expectEqualStrings("model", migration.bytes);
    const older = Store.init(std.testing.io, std.testing.allocator, path, .{ .schema_version = 1, .model_fingerprint = 9, .snapshot_format = 1 });
    try std.testing.expectEqual(Outcome.version_unknown, older.restore().outcome);
    const changed = Store.init(std.testing.io, std.testing.allocator, path, .{ .schema_version = 2, .model_fingerprint = 10, .snapshot_format = 1 });
    try std.testing.expectEqual(Outcome.corrupt, changed.restore().outcome);
}

test "snapshot store refuses downgrade writes and preserves the future generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try testDirPath(&tmp, &path_buffer);
    const future = Store.init(std.testing.io, std.testing.allocator, path, .{
        .schema_version = 3,
        .model_fingerprint = 30,
        .snapshot_format = 2,
    });
    try std.testing.expectEqual(Outcome.ok, future.write("future model"));

    const rollback = Store.init(std.testing.io, std.testing.allocator, path, .{
        .schema_version = 2,
        .model_fingerprint = 20,
        .snapshot_format = 1,
    });
    try std.testing.expectEqual(Outcome.version_unknown, rollback.restore().outcome);
    try std.testing.expectEqual(Outcome.version_unknown, rollback.write("rollback model"));
    try std.testing.expectEqual(Outcome.version_unknown, rollback.write("second rollback model"));

    var restored = future.restore();
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.ok, restored.outcome);
    try std.testing.expectEqualStrings("future model", restored.bytes);

    var backup_buffer: [512]u8 = undefined;
    const backup = joinPath(&backup_buffer, path, backup_name).?;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, backup, std.testing.allocator, .limited(header_len + max_snapshot_bytes));
    try std.testing.expectError(error.FileNotFound, bytes);

    // A torn future primary still leaves a future backup. Rollback writes must
    // protect that last recoverable generation too.
    try std.testing.expectEqual(Outcome.ok, future.write("newest future model"));
    var primary_buffer: [512]u8 = undefined;
    const primary = joinPath(&primary_buffer, path, snapshot_name).?;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = primary, .data = "torn" });
    try std.testing.expectEqual(Outcome.version_unknown, rollback.write("rollback over torn primary"));

    var recovered = future.restore();
    defer recovered.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.ok, recovered.outcome);
    try std.testing.expectEqualStrings("future model", recovered.bytes);
    try std.testing.expect(recovered.used_backup);
}

test "snapshot store rejects over-bound models without touching disk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try testDirPath(&tmp, &path_buffer);
    const store = Store.init(std.testing.io, std.testing.allocator, path, .{ .schema_version = 1, .model_fingerprint = 1, .snapshot_format = 1 });
    const oversized = try std.testing.allocator.alloc(u8, max_snapshot_bytes + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectEqual(Outcome.rejected, store.write(oversized));
    try std.testing.expectEqual(Outcome.none, store.restore().outcome);
}

test "snapshot coordinator coalesces to the trailing snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try testDirPath(&tmp, &path_buffer);
    const store = Store.init(std.testing.io, std.heap.page_allocator, path, .{ .schema_version = 1, .model_fingerprint = 1, .snapshot_format = 1 });
    var coordinator: Coordinator = undefined;
    try coordinator.start(store, 50);
    try std.testing.expectEqual(Outcome.ok, coordinator.enqueue("superseded"));
    try std.testing.expectEqual(Outcome.ok, coordinator.enqueue("latest"));
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(80), .awake);
    coordinator.deinit();

    var restored = store.restore();
    defer restored.deinit(std.heap.page_allocator);
    try std.testing.expectEqual(Outcome.ok, restored.outcome);
    try std.testing.expectEqualStrings("latest", restored.bytes);

    var backup_buffer: [512]u8 = undefined;
    const backup = joinPath(&backup_buffer, path, backup_name).?;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, backup, std.testing.allocator, .limited(header_len + max_snapshot_bytes));
    try std.testing.expectError(error.FileNotFound, bytes);
}

test "snapshot coordinator force-flushes its tail on lifecycle flush" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try testDirPath(&tmp, &path_buffer);
    const store = Store.init(std.testing.io, std.heap.page_allocator, path, .{ .schema_version = 1, .model_fingerprint = 1, .snapshot_format = 1 });
    var coordinator: Coordinator = undefined;
    try coordinator.start(store, 60_000);
    defer coordinator.deinit();
    try std.testing.expectEqual(Outcome.ok, coordinator.enqueue("quit tail"));
    coordinator.flush();

    var restored = store.restore();
    defer restored.deinit(std.heap.page_allocator);
    try std.testing.expectEqual(Outcome.ok, restored.outcome);
    try std.testing.expectEqualStrings("quit tail", restored.bytes);
}

test "snapshot coordinator reports worker I/O failures through its terminal hook" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try testDirPath(&tmp, &path_buffer);
    // A regular file at the would-be data directory makes createDirPath fail
    // deterministically after the request has reached the worker.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "not a directory" });
    const store = Store.init(std.testing.io, std.heap.page_allocator, path, .{ .schema_version = 1, .model_fingerprint = 1, .snapshot_format = 1 });
    const Capture = struct {
        seen: Outcome = .ok,

        fn report(context: *anyopaque, outcome: Outcome) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.seen = outcome;
        }
    };
    var capture: Capture = .{};
    var coordinator: Coordinator = undefined;
    try coordinator.startWithOutcomeHandler(store, 60_000, .{ .context = &capture, .report_fn = Capture.report });
    defer coordinator.deinit();
    try std.testing.expectEqual(Outcome.ok, coordinator.enqueue("cannot land"));
    coordinator.flush();
    try std.testing.expectEqual(Outcome.io_failed, capture.seen);
}
