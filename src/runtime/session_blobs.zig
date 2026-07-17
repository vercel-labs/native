//! Session blob store: content-addressed payload storage beside the
//! session journal.
//!
//! Some effect results are too big — and too binary — to inline in
//! journal records: an image load's ENCODED source bytes are the whole
//! effect result, and replaying them byte-identically is the point. So
//! the journal record carries only a content address (the first 16
//! bytes of the payload's SHA-256, the `audioCachePath` hashing
//! convention) plus the length, and the bytes live as one file per
//! distinct payload under `blobs/` next to the journal file:
//!
//!   <session_dir>/session.journal
//!   <session_dir>/blobs/<32-hex-chars>
//!
//! Content addressing gives deduplication for free — recording the same
//! bytes twice (a cache hit replaying the same image, two loads of one
//! asset) writes one blob — and makes the store verifiable: replay
//! re-hashes what it reads and refuses a store whose bytes do not match
//! their name, the same hostile-input honesty the journal itself keeps.
//!
//! Two type-erased seams keep the recorder and replayer storage-
//! agnostic: `SessionBlobSink` (recording) and `SessionBlobSource`
//! (replay). `DirBlobStore` backs them with a directory over `std.Io`
//! (the app runner's wiring); `MemoryBlobStore` backs them in memory
//! for tests.

const std = @import("std");
const runtime_effects = @import("effects.zig");

/// Bytes of a blob's content address (SHA-256 prefix); hex-encoded it
/// is the blob's file name.
pub const hash_len: usize = runtime_effects.effect_image_blob_hash_len;

/// The largest payload one blob may hold — the largest journaled effect
/// payload that goes out of line (an image load's encoded source).
pub const max_blob_bytes: usize = runtime_effects.max_effect_image_bytes;

pub const BlobHash = [hash_len]u8;

/// Content address of `bytes`.
pub fn hashBytes(bytes: []const u8) BlobHash {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest[0..hash_len].*;
}

/// A blob's file name: the address in lowercase hex, no extension (the
/// bytes are an opaque payload; decoders sniff content, not names).
pub fn hexName(hash: BlobHash) [hash_len * 2]u8 {
    return std.fmt.bytesToHex(hash, .lower);
}

pub const BlobError = error{
    /// The store has no blob under this address — the journal names
    /// bytes the store never received (a moved journal without its
    /// blobs directory, or a damaged store).
    BlobMissing,
    /// The stored bytes do not hash to their address, or their length
    /// disagrees with the journal record: the store was damaged or
    /// hand-edited.
    BlobCorrupt,
    /// The blob claims a payload beyond `max_blob_bytes`.
    BlobOverBudget,
    /// The store could not be written (recording) or read (replay).
    BlobIoFailed,
};

/// Where recorded blobs go. `write_fn` must be idempotent per address —
/// content addressing means a repeat write of the same bytes is a no-op
/// by construction, and implementations should skip the copy.
pub const SessionBlobSink = struct {
    context: *anyopaque,
    write_fn: *const fn (context: *anyopaque, hash: BlobHash, bytes: []const u8) BlobError!void,
};

/// Where replayed blobs come from. `read_fn` fills `buffer` and returns
/// the blob's bytes (a prefix of `buffer`); implementations verify the
/// content hash before answering.
pub const SessionBlobSource = struct {
    context: *anyopaque,
    read_fn: *const fn (context: *anyopaque, hash: BlobHash, buffer: []u8) BlobError![]const u8,
};

/// A directory-backed blob store over `std.Io` — the app runner's
/// implementation for both recording and replay. Writes are atomic
/// (beside-then-rename, the cache-install discipline) and deduplicated
/// by an existence probe; reads re-hash and refuse mismatches.
pub const DirBlobStore = struct {
    io: std.Io,
    dir_storage: [max_dir_bytes]u8 = undefined,
    dir_len: usize = 0,

    pub const max_dir_bytes: usize = 1024;

    pub fn init(io: std.Io, dir_path: []const u8) error{BlobDirTooLong}!DirBlobStore {
        if (dir_path.len == 0 or dir_path.len > max_dir_bytes) return error.BlobDirTooLong;
        var store: DirBlobStore = .{ .io = io };
        @memcpy(store.dir_storage[0..dir_path.len], dir_path);
        store.dir_len = dir_path.len;
        return store;
    }

    pub fn dir(self: *const DirBlobStore) []const u8 {
        return self.dir_storage[0..self.dir_len];
    }

    pub fn sink(self: *DirBlobStore) SessionBlobSink {
        return .{ .context = self, .write_fn = writeErased };
    }

    pub fn source(self: *DirBlobStore) SessionBlobSource {
        return .{ .context = self, .read_fn = readErased };
    }

    pub fn write(self: *DirBlobStore, hash: BlobHash, bytes: []const u8) BlobError!void {
        if (bytes.len > max_blob_bytes) return error.BlobOverBudget;
        const cwd = std.Io.Dir.cwd();
        var path_buffer: [max_dir_bytes + hash_len * 2 + 16]u8 = undefined;
        const name = hexName(hash);
        const blob_path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ self.dir(), name }) catch return error.BlobIoFailed;
        // Content addressing: an existing blob under this name IS these
        // bytes (replay verifies) — the dedup case costs one probe.
        if (cwd.openFile(self.io, blob_path, .{})) |file_value| {
            var file = file_value;
            file.close(self.io);
            return;
        } else |_| {}
        cwd.createDirPath(self.io, self.dir()) catch return error.BlobIoFailed;
        var partial_buffer: [max_dir_bytes + hash_len * 2 + 16]u8 = undefined;
        const partial_path = std.fmt.bufPrint(&partial_buffer, "{s}/{s}.partial", .{ self.dir(), name }) catch return error.BlobIoFailed;
        cwd.writeFile(self.io, .{ .sub_path = partial_path, .data = bytes }) catch return error.BlobIoFailed;
        cwd.rename(partial_path, cwd, blob_path, self.io) catch return error.BlobIoFailed;
    }

    pub fn read(self: *DirBlobStore, hash: BlobHash, buffer: []u8) BlobError![]const u8 {
        const cwd = std.Io.Dir.cwd();
        var path_buffer: [max_dir_bytes + hash_len * 2 + 16]u8 = undefined;
        const name = hexName(hash);
        const blob_path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ self.dir(), name }) catch return error.BlobIoFailed;
        var file = cwd.openFile(self.io, blob_path, .{}) catch return error.BlobMissing;
        defer file.close(self.io);
        const len = file.readPositionalAll(self.io, buffer, 0) catch return error.BlobIoFailed;
        if (len == buffer.len) return error.BlobOverBudget;
        const bytes = buffer[0..len];
        if (!std.mem.eql(u8, &hashBytes(bytes), &hash)) return error.BlobCorrupt;
        return bytes;
    }

    fn writeErased(context: *anyopaque, hash: BlobHash, bytes: []const u8) BlobError!void {
        const self: *DirBlobStore = @ptrCast(@alignCast(context));
        return self.write(hash, bytes);
    }

    fn readErased(context: *anyopaque, hash: BlobHash, buffer: []u8) BlobError![]const u8 {
        const self: *DirBlobStore = @ptrCast(@alignCast(context));
        return self.read(hash, buffer);
    }
};

/// An in-memory blob store for tests: allocator-backed, bounded, and
/// honest about capacity. Write dedups by address; read verifies the
/// hash like the directory store, so a test store misbehaves exactly
/// as loudly as the real one.
pub const MemoryBlobStore = struct {
    allocator: std.mem.Allocator,
    entries: [max_entries]Entry = undefined,
    count: usize = 0,
    /// How many writes found their address already present — the dedup
    /// evidence tests assert on.
    dedup_hits: usize = 0,

    pub const max_entries: usize = 32;

    const Entry = struct {
        hash: BlobHash,
        bytes: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) MemoryBlobStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryBlobStore) void {
        for (self.entries[0..self.count]) |entry| self.allocator.free(entry.bytes);
        self.count = 0;
    }

    pub fn sink(self: *MemoryBlobStore) SessionBlobSink {
        return .{ .context = self, .write_fn = writeErased };
    }

    pub fn source(self: *MemoryBlobStore) SessionBlobSource {
        return .{ .context = self, .read_fn = readErased };
    }

    pub fn write(self: *MemoryBlobStore, hash: BlobHash, bytes: []const u8) BlobError!void {
        if (bytes.len > max_blob_bytes) return error.BlobOverBudget;
        if (self.find(hash) != null) {
            self.dedup_hits += 1;
            return;
        }
        if (self.count == max_entries) return error.BlobIoFailed;
        const copy = self.allocator.dupe(u8, bytes) catch return error.BlobIoFailed;
        self.entries[self.count] = .{ .hash = hash, .bytes = copy };
        self.count += 1;
    }

    pub fn read(self: *MemoryBlobStore, hash: BlobHash, buffer: []u8) BlobError![]const u8 {
        const entry = self.find(hash) orelse return error.BlobMissing;
        if (entry.bytes.len > buffer.len) return error.BlobOverBudget;
        @memcpy(buffer[0..entry.bytes.len], entry.bytes);
        const bytes = buffer[0..entry.bytes.len];
        if (!std.mem.eql(u8, &hashBytes(bytes), &hash)) return error.BlobCorrupt;
        return bytes;
    }

    fn find(self: *MemoryBlobStore, hash: BlobHash) ?*Entry {
        for (self.entries[0..self.count]) |*entry| {
            if (std.mem.eql(u8, &entry.hash, &hash)) return entry;
        }
        return null;
    }

    fn writeErased(context: *anyopaque, hash: BlobHash, bytes: []const u8) BlobError!void {
        const self: *MemoryBlobStore = @ptrCast(@alignCast(context));
        return self.write(hash, bytes);
    }

    fn readErased(context: *anyopaque, hash: BlobHash, buffer: []u8) BlobError![]const u8 {
        const self: *MemoryBlobStore = @ptrCast(@alignCast(context));
        return self.read(hash, buffer);
    }
};

// -------------------------------------------------------------- tests

const testing = std.testing;

test "content addresses are stable and hex names filesystem-safe" {
    const hash = hashBytes("the same bytes");
    try testing.expectEqualSlices(u8, &hash, &hashBytes("the same bytes"));
    try testing.expect(!std.mem.eql(u8, &hash, &hashBytes("different bytes")));
    const name = hexName(hash);
    for (name) |char| {
        try testing.expect((char >= '0' and char <= '9') or (char >= 'a' and char <= 'f'));
    }
}

test "memory store round-trips, dedups identical bytes, and refuses damage" {
    var store = MemoryBlobStore.init(testing.allocator);
    defer store.deinit();

    const bytes = "png bytes, say";
    const hash = hashBytes(bytes);
    try store.write(hash, bytes);
    try store.write(hash, bytes);
    try testing.expectEqual(@as(usize, 1), store.count);
    try testing.expectEqual(@as(usize, 1), store.dedup_hits);

    var buffer: [64]u8 = undefined;
    const read_back = try store.read(hash, &buffer);
    try testing.expectEqualStrings(bytes, read_back);

    try testing.expectError(error.BlobMissing, store.read(hashBytes("never written"), &buffer));
    // A tampered entry no longer hashes to its address.
    store.entries[0].bytes[0] ^= 0x40;
    try testing.expectError(error.BlobCorrupt, store.read(hash, &buffer));
}

test "dir store writes atomically, dedups by existence, and verifies on read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buffer: [256]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path[0..]});
    var store = try DirBlobStore.init(io, dir_path);

    const bytes = "encoded image bytes";
    const hash = hashBytes(bytes);
    try store.write(hash, bytes);
    try store.write(hash, bytes);

    var read_buffer: [4096]u8 = undefined;
    const read_back = try store.read(hash, &read_buffer);
    try testing.expectEqualStrings(bytes, read_back);

    // Exactly one blob file, no .partial debris.
    var blob_dir = try tmp.dir.openDir(io, "blobs", .{ .iterate = true });
    defer blob_dir.close(io);
    var iterator = blob_dir.iterate();
    var file_count: usize = 0;
    while (try iterator.next(io)) |entry| {
        try testing.expect(!std.mem.endsWith(u8, entry.name, ".partial"));
        file_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), file_count);

    try testing.expectError(error.BlobMissing, store.read(hashBytes("absent"), &read_buffer));

    // Damaged bytes are refused, never returned as the payload.
    const name = hexName(hash);
    var damaged: [64]u8 = undefined;
    @memcpy(damaged[0..bytes.len], bytes);
    damaged[0] ^= 0x40;
    var path_buffer: [300]u8 = undefined;
    const rel = try std.fmt.bufPrint(&path_buffer, "blobs/{s}", .{name});
    try tmp.dir.writeFile(io, .{ .sub_path = rel, .data = damaged[0..bytes.len] });
    try testing.expectError(error.BlobCorrupt, store.read(hash, &read_buffer));
}
