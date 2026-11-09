//! The retained widget-provenance table (write-back's read half): one
//! record per markup-authored widget of a `UiApp` canvas view, keyed by
//! structural id, filled by the builder's provenance sink on every rebuild
//! while automation is enabled. The `provenance` automation verb reads it;
//! the edit verbs anchor file writes on its spans and file hashes.
//!
//! Fixed-capacity like every retained pool (`canvas_limits` budgets); the
//! table only exists in markup-interpreter builds (`UiAppFeatures
//! .runtime_markup`), so release apps carry none of it. Records reset per
//! rebuild; the file table resets per markup (re)load, because that is
//! when file contents — and therefore spans and hashes — change.

const std = @import("std");
const canvas = @import("canvas");
const canvas_limits = @import("canvas_limits.zig");

pub const max_records = canvas_limits.max_canvas_widget_provenance_records_per_view;
pub const max_files = canvas_limits.max_canvas_widget_provenance_files;
pub const max_path_bytes = canvas_limits.max_canvas_widget_provenance_path_bytes;
pub const max_chain = canvas_limits.max_canvas_widget_provenance_chain;
pub const max_key_bytes = canvas_limits.max_canvas_widget_provenance_key_bytes;

/// Sentinel file index for a record whose stamped path missed the file
/// table (a bug guard, not an expected state: records and table come from
/// the same resolved closure).
pub const unknown_file: u8 = 0xFF;

pub const FileEntry = struct {
    /// The path as `MarkupNode.src_path` stamps it (resolver-relative;
    /// empty for a single-file document's root).
    stamped_storage: [max_path_bytes]u8 = undefined,
    stamped_len: usize = 0,
    /// The file's path on disk relative to the app's working directory —
    /// the directory the automation CLI shares (the dropbox contract).
    /// Empty when the app is not watching markup sources, in which case
    /// write-back has no file to edit and refuses.
    file_storage: [max_path_bytes]u8 = undefined,
    file_len: usize = 0,
    /// Wyhash(0, bytes) of the source the app LOADED for this file. The
    /// edit verb compares it against the on-disk bytes before writing —
    /// a mismatch means concurrent edits (or a not-yet-reloaded app) and
    /// the write is refused, never clobbered.
    hash: u64 = 0,

    pub fn stamped(self: *const FileEntry) []const u8 {
        return self.stamped_storage[0..self.stamped_len];
    }

    pub fn file(self: *const FileEntry) []const u8 {
        return self.file_storage[0..self.file_len];
    }
};

pub const ChainRef = struct {
    file: u8 = unknown_file,
    start: u32 = 0,
    end: u32 = 0,
    line: u32 = 0,
    column: u32 = 0,
};

pub const Record = struct {
    id: u64 = 0,
    file: u8 = unknown_file,
    start: u32 = 0,
    end: u32 = 0,
    line: u32 = 0,
    column: u32 = 0,
    chain_len: u8 = 0,
    chain_truncated: bool = false,
    chain: [max_chain]ChainRef = undefined,
    keys_len: u8 = 0,
    keys_truncated: bool = false,
    keys: [max_key_bytes]u8 = undefined,
};

/// Import-closure staging: the files (resolver-relative path + content
/// hash) one resolve pass loaded, recorded by the app's hashing loader
/// and committed into a `ProvenanceTable`'s file table only when the
/// resolved document is ADOPTED — a failed mid-edit reload must never
/// re-anchor provenance to bytes the running view was not built from.
pub const ClosureFiles = struct {
    pub const Entry = struct {
        path: [max_path_bytes]u8 = undefined,
        path_len: usize = 0,
        hash: u64 = 0,
    };

    entries: [max_files - 1]Entry = undefined,
    len: usize = 0,
    overflow: bool = false,

    pub fn reset(self: *ClosureFiles) void {
        self.len = 0;
        self.overflow = false;
    }

    pub fn add(self: *ClosureFiles, path: []const u8, hash: u64) void {
        if (self.len >= self.entries.len) {
            self.overflow = true;
            return;
        }
        var entry = &self.entries[self.len];
        entry.path_len = @min(path.len, entry.path.len);
        @memcpy(entry.path[0..entry.path_len], path[0..entry.path_len]);
        entry.hash = hash;
        self.len += 1;
    }
};

pub const ProvenanceTable = struct {
    files: [max_files]FileEntry = undefined,
    files_len: usize = 0,
    /// Whether the app watches markup sources on disk: with a watch, the
    /// per-file `file()` paths are real files the edit verb may write and
    /// hot reload will pick up; without one, provenance is read-only.
    watching: bool = false,
    records: [max_records]Record = undefined,
    records_len: usize = 0,
    /// Records refused because the pool was full. Non-zero turns "no
    /// record for this id" from "authored in Zig" into "unknown", and the
    /// response says so — silence never lies about saturation.
    dropped: usize = 0,

    pub fn resetRecords(self: *ProvenanceTable) void {
        self.records_len = 0;
        self.dropped = 0;
    }

    pub fn resetFiles(self: *ProvenanceTable) void {
        self.files_len = 0;
        self.watching = false;
    }

    /// Register one source file of the loaded closure. Paths beyond the
    /// storage cap truncate (they could never match a stamped path, so
    /// the record falls back to `unknown_file` honestly).
    pub fn addFile(self: *ProvenanceTable, stamped_path: []const u8, file_path: []const u8, hash: u64) error{WidgetProvenanceFileLimitReached}!void {
        if (self.files_len >= self.files.len) return error.WidgetProvenanceFileLimitReached;
        var entry = &self.files[self.files_len];
        entry.stamped_len = @min(stamped_path.len, entry.stamped_storage.len);
        @memcpy(entry.stamped_storage[0..entry.stamped_len], stamped_path[0..entry.stamped_len]);
        entry.file_len = @min(file_path.len, entry.file_storage.len);
        @memcpy(entry.file_storage[0..entry.file_len], file_path[0..entry.file_len]);
        entry.hash = hash;
        self.files_len += 1;
    }

    pub fn fileIndexOf(self: *const ProvenanceTable, stamped_path: []const u8) ?u8 {
        for (self.files[0..self.files_len], 0..) |*entry, index| {
            if (std.mem.eql(u8, entry.stamped(), stamped_path)) return @intCast(index);
        }
        return null;
    }

    /// Append one record; the named one-past error is the budget contract
    /// (`canvas_limits.max_canvas_widget_provenance_records_per_view`).
    /// The pool mirrors the layout node budget, so a view that layout
    /// accepts can never overflow it — the sink still degrades (counts
    /// `dropped`) rather than failing a build, because provenance is
    /// observability, never the reason a frame dies.
    pub fn appendRecord(self: *ProvenanceTable, id: u64, source: *const canvas.ui_provenance.NodeSource, keys: []const canvas.ui_provenance.Key, keys_truncated: bool) error{WidgetProvenanceLimitReached}!void {
        if (self.records_len >= self.records.len) return error.WidgetProvenanceLimitReached;
        var record = &self.records[self.records_len];
        record.* = .{
            .id = id,
            .file = self.fileIndexOf(source.src_path) orelse unknown_file,
            .start = clampU32(source.span.start),
            .end = clampU32(source.span.end),
            .line = clampU32(source.line),
            .column = clampU32(source.column),
        };
        for (source.chain) |site| {
            if (record.chain_len >= record.chain.len) {
                record.chain_truncated = true;
                break;
            }
            record.chain[record.chain_len] = .{
                .file = self.fileIndexOf(site.src_path) orelse unknown_file,
                .start = clampU32(site.span.start),
                .end = clampU32(site.span.end),
                .line = clampU32(site.line),
                .column = clampU32(site.column),
            };
            record.chain_len += 1;
        }
        record.keys_truncated = keys_truncated;
        var writer = std.Io.Writer.fixed(&record.keys);
        for (keys, 0..) |key, index| {
            if (index > 0) writeKeyByte(&writer, '/', record);
            switch (key) {
                .index => |value| writer.print("{d}", .{value}) catch {
                    record.keys_truncated = true;
                    break;
                },
                .int => |value| writer.print("{d}", .{value}) catch {
                    record.keys_truncated = true;
                    break;
                },
                .str => |value| for (value) |byte| {
                    // 0x1f separates `forSlotKey` slot suffixes; other
                    // control bytes would tear the line protocol.
                    writeKeyByte(&writer, if (byte < 0x20 or byte == 0x7F) ':' else byte, record);
                },
            }
            if (record.keys_truncated) break;
        }
        record.keys_len = @intCast(writer.buffered().len);
        self.records_len += 1;
    }

    /// The sink `Ui.finalize` feeds (see `canvas.ui_provenance.Sink`).
    pub fn sink(self: *ProvenanceTable) canvas.ui_provenance.Sink {
        return .{ .context = @ptrCast(self), .record_fn = sinkRecord };
    }

    fn sinkRecord(context: *anyopaque, id: u64, source: *const canvas.ui_provenance.NodeSource, keys: []const canvas.ui_provenance.Key, keys_truncated: bool) void {
        const self: *ProvenanceTable = @ptrCast(@alignCast(context));
        self.appendRecord(id, source, keys, keys_truncated) catch {
            self.dropped += 1;
        };
    }

    pub fn find(self: *const ProvenanceTable, id: u64) ?*const Record {
        for (self.records[0..self.records_len]) |*record| {
            if (record.id == id) return record;
        }
        return null;
    }

    /// The `provenance` verb's response text for one widget id. The
    /// widget's existence in the live tree is the caller's check; this
    /// answers "where was it authored".
    pub fn writeResponse(self: *const ProvenanceTable, writer: *std.Io.Writer, view_label: []const u8, id: u64) !void {
        if (self.find(id)) |record| {
            const root_file = if (self.files_len > 0) self.files[0].file() else "";
            try writer.print("provenance ok view={s} id={d} authored=markup watching={} root={s}\n", .{ view_label, id, self.watching, root_file });
            try self.writeSite(writer, "node", record.file, record.start, record.end, record.line, record.column);
            var index: usize = 0;
            while (index < record.chain_len) : (index += 1) {
                const site = record.chain[index];
                try self.writeSite(writer, "use", site.file, site.start, site.end, site.line, site.column);
            }
            if (record.chain_truncated) try writer.writeAll("chain_truncated=true\n");
            if (record.keys_len > 0 or record.keys_truncated) {
                try writer.print("keys={s} keys_truncated={}\n", .{ record.keys[0..record.keys_len], record.keys_truncated });
            }
            return;
        }
        if (self.dropped > 0) {
            try writer.print(
                "provenance error view={s} id={d} message=\"provenance pool saturated ({d} records dropped; canvas_limits.max_canvas_widget_provenance_records_per_view) - this widget's record may be among the dropped\"\n",
                .{ view_label, id, self.dropped },
            );
            return;
        }
        try writer.print(
            "provenance ok view={s} id={d} authored=zig message=\"no markup source: this widget was authored in Zig (the builder API) or synthesized by the engine - write-back edits markup files only, so find the ui.* call in the app's view code\"\n",
            .{ view_label, id },
        );
    }

    fn writeSite(self: *const ProvenanceTable, writer: *std.Io.Writer, tag: []const u8, file_index: u8, start: u32, end: u32, line: u32, column: u32) !void {
        try writer.print("{s} ", .{tag});
        if (file_index != unknown_file and file_index < self.files_len) {
            const entry = &self.files[file_index];
            try writer.print("file={s} stamped={s} hash={x:0>16}", .{ entry.file(), entry.stamped(), entry.hash });
        } else {
            try writer.writeAll("file= stamped= hash=0");
        }
        try writer.print(" span={d}..{d} line={d} column={d}\n", .{ start, end, line, column });
    }
};

fn clampU32(value: usize) u32 {
    return @intCast(@min(value, std.math.maxInt(u32)));
}

fn writeKeyByte(writer: *std.Io.Writer, byte: u8, record: *Record) void {
    writer.writeByte(byte) catch {
        record.keys_truncated = true;
    };
}

test "provenance table records, finds, and formats" {
    var table = ProvenanceTable{};
    try table.addFile("", "src/board.native", 0xabcd);
    try table.addFile("components/pill.native", "src/components/pill.native", 0x1234);
    table.watching = true;

    const chain = [_]canvas.ui_provenance.UseSite{
        .{ .src_path = "", .span = .{ .start = 100, .end = 140 }, .line = 9, .column = 5 },
    };
    const source = canvas.ui_provenance.NodeSource{
        .src_path = "components/pill.native",
        .span = .{ .start = 40, .end = 90 },
        .line = 2,
        .column = 3,
        .chain = &chain,
    };
    const keys = [_]canvas.ui_provenance.Key{ .{ .str = "card-7" }, .{ .index = 2 } };
    try table.appendRecord(77, &source, &keys, false);

    const record = table.find(77).?;
    try std.testing.expectEqual(@as(u8, 1), record.file);
    try std.testing.expectEqual(@as(u8, 1), record.chain_len);
    try std.testing.expectEqualStrings("card-7/2", record.keys[0..record.keys_len]);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try table.writeResponse(&writer, "kanban-canvas", 77);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "authored=markup") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "node file=src/components/pill.native") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "use file=src/board.native") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "keys=card-7/2") != null);

    writer = std.Io.Writer.fixed(&buffer);
    try table.writeResponse(&writer, "kanban-canvas", 999);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "authored=zig") != null);
}

test "provenance pool budget: at capacity applies, one past errors named, no half-apply" {
    var table = ProvenanceTable{};
    try table.addFile("", "src/app.native", 1);
    const source = canvas.ui_provenance.NodeSource{ .src_path = "", .span = .{ .start = 0, .end = 4 }, .line = 1, .column = 1 };
    var index: usize = 0;
    while (index < max_records) : (index += 1) {
        try table.appendRecord(index + 1, &source, &.{}, false);
    }
    try std.testing.expectEqual(max_records, table.records_len);
    try std.testing.expectError(error.WidgetProvenanceLimitReached, table.appendRecord(max_records + 1, &source, &.{}, false));
    try std.testing.expectEqual(max_records, table.records_len);
    // The sink degrades instead of failing the frame, and says so.
    table.sink().record(max_records + 1, &source, &.{}, false);
    try std.testing.expectEqual(@as(usize, 1), table.dropped);
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try table.writeResponse(&writer, "v", 12345678);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "provenance pool saturated") != null);
    // Survival: reset and record again.
    table.resetRecords();
    try table.appendRecord(1, &source, &.{}, false);
    try std.testing.expectEqual(@as(usize, 1), table.records_len);
}

test "provenance record caps truncate honestly" {
    var table = ProvenanceTable{};
    try table.addFile("a.native", "src/a.native", 1);
    var chain: [max_chain + 2]canvas.ui_provenance.UseSite = undefined;
    for (&chain) |*site| site.* = .{ .src_path = "a.native", .span = .{ .start = 1, .end = 2 }, .line = 1, .column = 1 };
    const source = canvas.ui_provenance.NodeSource{ .src_path = "a.native", .span = .{ .start = 0, .end = 4 }, .chain = &chain };
    const long_key = "k" ** (max_key_bytes + 8);
    const keys = [_]canvas.ui_provenance.Key{.{ .str = long_key }};
    try table.appendRecord(5, &source, &keys, false);
    const record = table.find(5).?;
    try std.testing.expectEqual(@as(u8, max_chain), record.chain_len);
    try std.testing.expect(record.chain_truncated);
    try std.testing.expect(record.keys_truncated);
    try std.testing.expectEqual(@as(u8, max_key_bytes), record.keys_len);
}

test "file table one past errors named" {
    var table = ProvenanceTable{};
    var index: usize = 0;
    while (index < max_files) : (index += 1) {
        try table.addFile("x.native", "src/x.native", index);
    }
    try std.testing.expectError(error.WidgetProvenanceFileLimitReached, table.addFile("y.native", "src/y.native", 1));
}
