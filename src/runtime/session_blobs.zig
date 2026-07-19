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
//! asset) writes one blob — and makes the store verifiable at BOTH
//! ends: replay re-hashes what it reads and refuses a store whose bytes
//! do not match their name, and recording's dedup probe reads the
//! existing file back before trusting it, repairing a mismatch in place
//! through the same atomic install a fresh write uses. A damaged blob
//! is a repairable state while the true bytes are in hand — recording
//! self-heals it instead of sealing a journal that replay must refuse.
//!
//! Two type-erased seams keep the recorder and replayer storage-
//! agnostic: `SessionBlobSink` (recording) and `SessionBlobSource`
//! (replay). `DirBlobStore` backs them with a directory over `std.Io`
//! (the app runner's wiring); `MemoryBlobStore` backs them in memory
//! for tests.

const std = @import("std");
const runtime_effects = @import("effects.zig");

const blob_log = std.log.scoped(.zero_session_blobs);

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

/// The temp path one blob write stages before its atomic rename into
/// the addressed name. `token` is the write's own random draw, and it
/// carries the WHOLE writer-uniqueness: the directory is shared between
/// recorders and the name is the content hash, so every other component
/// is identical when two recorders write the same blob — a temp built
/// without the token is one file both writers fight over. The name
/// stays recognizable install debris (`<hash>.<token>.partial` beside
/// its blob) for a hard crash to leave behind. A pure formatter: the
/// entropy lives with the caller.
fn blobPartialPath(buffer: []u8, dir_path: []const u8, name: []const u8, token: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}.{x:0>16}.partial", .{ dir_path, name, token });
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
/// by construction, and implementations should skip the copy AFTER
/// verifying the stored bytes really are these bytes (a damaged blob is
/// repaired from the bytes in hand, never trusted by name).
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
/// by a VERIFYING probe — an existing file under the address is read
/// back and must hold exactly the incoming bytes, or the write repairs
/// it in place; reads re-hash and refuse mismatches.
///
/// The directory is a SHARED medium: two recorders (two app processes,
/// or two stores in one process) may write the same blob into one
/// blobs/ directory concurrently. Two disciplines keep that safe:
/// every write stages through a WRITER-unique temp (a random token in
/// the name — a temp named by the hash alone would be one file both
/// writers truncate and rename out from under each other), and a
/// rename that still fails gets the content-addressed grace — when the
/// addressed name already holds exactly the bytes being written, some
/// writer won with THIS content, so the write succeeded (only a
/// verified mismatch or absence stays `BlobIoFailed`).
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
        // Content addressing dedups by name, but recording never TRUSTS
        // the name alone: replay verifies what it reads, so a damaged
        // blob accepted here would seal a journal replay must refuse.
        // The probe reads the existing file back (bounded by the bytes
        // in hand, themselves under max_blob_bytes) and skips the write
        // only on an exact match; anything else — damage, truncation,
        // an unreadable file — is a repairable state while the true
        // bytes are right here, so it falls through to the same atomic
        // partial+rename a fresh write uses. Cost: a dedup hit is one
        // bounded read instead of one existence probe.
        switch (self.probeExisting(blob_path, bytes)) {
            .matches => return,
            .absent => {},
            .mismatch => blob_log.debug("blob {s} does not hold its addressed bytes; repairing in place", .{name}),
        }
        cwd.createDirPath(self.io, self.dir()) catch return error.BlobIoFailed;
        // The temp name must be WRITER-unique, not merely blob-unique:
        // two recorders sharing one blobs/ directory write the same
        // blob under the same hash, and a temp named by the hash alone
        // is ONE file both writers truncate mid-write and rename out
        // from under each other (the loser's rename then fails a
        // correct recording). The token is the write's own random draw
        // from the store's io (the CSPRNG seam the executor's cache
        // installs already use), unique across stores and processes
        // alike.
        var token_bytes: [8]u8 = undefined;
        self.io.random(&token_bytes);
        const token = std.mem.readInt(u64, &token_bytes, .little);
        var partial_buffer: [max_dir_bytes + hash_len * 2 + 48]u8 = undefined;
        const partial_path = blobPartialPath(&partial_buffer, self.dir(), &name, token) catch return error.BlobIoFailed;
        cwd.writeFile(self.io, .{ .sub_path = partial_path, .data = bytes }) catch {
            cwd.deleteFile(self.io, partial_path) catch {};
            return error.BlobIoFailed;
        };
        return self.installPartial(partial_path, blob_path, bytes);
    }

    /// The atomic tail of `write`: rename the writer-unique temp into
    /// the blob's addressed name. A failed rename is not yet a failed
    /// WRITE — the store is content-addressed, so if the addressed name
    /// already holds exactly these bytes, a concurrent writer won the
    /// install with the same content and this write SUCCEEDED (its
    /// bytes are durable under their address; only who renamed them
    /// there differs). Re-running the verifying probe decides: a match
    /// returns cleanly, a verified mismatch or absence is the honest
    /// `BlobIoFailed`. The loser's temp is deleted on every failure
    /// path so no `.partial` debris outlives the write.
    fn installPartial(self: *DirBlobStore, partial_path: []const u8, blob_path: []const u8, bytes: []const u8) BlobError!void {
        const cwd = std.Io.Dir.cwd();
        cwd.rename(partial_path, cwd, blob_path, self.io) catch {
            defer cwd.deleteFile(self.io, partial_path) catch {};
            switch (self.probeExisting(blob_path, bytes)) {
                .matches => return,
                .absent, .mismatch => return error.BlobIoFailed,
            }
        };
    }

    const ProbeResult = enum { absent, matches, mismatch };

    /// The verifying half of the dedup probe: whether the file at
    /// `blob_path` holds exactly `bytes`. Compared chunk-wise against
    /// the incoming bytes (equality against the caller's bytes IS the
    /// hash check — their address is the file's name), so no
    /// blob-sized buffer is ever staged. A read failure mid-probe
    /// counts as a mismatch: the repair path rewrites the file whole.
    fn probeExisting(self: *DirBlobStore, blob_path: []const u8, bytes: []const u8) ProbeResult {
        var file = std.Io.Dir.cwd().openFile(self.io, blob_path, .{}) catch return .absent;
        defer file.close(self.io);
        var chunk: [4096]u8 = undefined;
        var at: usize = 0;
        while (true) {
            const len = file.readPositionalAll(self.io, &chunk, at) catch return .mismatch;
            if (len == 0) break;
            if (at + len > bytes.len) return .mismatch;
            if (!std.mem.eql(u8, chunk[0..len], bytes[at .. at + len])) return .mismatch;
            at += len;
            if (len < chunk.len) break;
        }
        return if (at == bytes.len) .matches else .mismatch;
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
/// honest about capacity. Write dedups by address with the directory
/// store's verifying probe (an entry that no longer holds its
/// addressed bytes is repaired in place); read verifies the hash like
/// the directory store, so a test store misbehaves exactly as loudly
/// as the real one. The directory store's two-writer race has no
/// analogue here: this store's medium is its own `entries` array, not
/// a shared directory — two recorders can never address one
/// MemoryBlobStore from two processes, and within one process each
/// recorder's sink drives its own store instance on its own thread —
/// so there is no shared temp to fight over and no rename to lose.
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
        if (self.find(hash)) |entry| {
            // The dir store's verifying dedup, in memory: an entry that
            // still holds its addressed bytes is the dedup hit; one
            // that no longer does (a tampering test — the dir store's
            // damaged-file case) is repaired in place rather than
            // trusted or refused.
            if (std.mem.eql(u8, entry.bytes, bytes)) {
                self.dedup_hits += 1;
                return;
            }
            const copy = self.allocator.dupe(u8, bytes) catch return error.BlobIoFailed;
            self.allocator.free(entry.bytes);
            entry.bytes = copy;
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

test "memory store repairs a tampered entry on the next same-bytes write" {
    var store = MemoryBlobStore.init(testing.allocator);
    defer store.deinit();

    const bytes = "encoded image bytes";
    const hash = hashBytes(bytes);
    try store.write(hash, bytes);
    store.entries[0].bytes[0] ^= 0x40;
    var buffer: [64]u8 = undefined;
    try testing.expectError(error.BlobCorrupt, store.read(hash, &buffer));

    // Recording the same bytes again finds the address occupied but
    // VERIFIES before trusting it: the damaged entry heals in place
    // (no dedup hit — a repair is not a dedup), and replay succeeds.
    try store.write(hash, bytes);
    try testing.expectEqual(@as(usize, 0), store.dedup_hits);
    try testing.expectEqual(@as(usize, 1), store.count);
    const read_back = try store.read(hash, &buffer);
    try testing.expectEqualStrings(bytes, read_back);
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

test "two recorders sharing one blobs directory both record the same blob successfully" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buffer: [256]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path[0..]});

    // Two DirBlobStore INSTANCES over one directory — the designed
    // shared layout when two recorders journal into one session
    // directory. Both write the same bytes (the same image loaded in
    // both recordings addresses the same blob) and BOTH writes must
    // succeed: a failure here invalidates a correct recording.
    var first_recorder = try DirBlobStore.init(io, dir_path);
    var second_recorder = try DirBlobStore.init(io, dir_path);

    const bytes = "encoded image bytes both sessions loaded";
    const hash = hashBytes(bytes);
    try first_recorder.write(hash, bytes);
    try second_recorder.write(hash, bytes);

    // One intact blob, readable through either store, zero temp debris.
    var read_buffer: [4096]u8 = undefined;
    try testing.expectEqualStrings(bytes, try first_recorder.read(hash, &read_buffer));
    try testing.expectEqualStrings(bytes, try second_recorder.read(hash, &read_buffer));
    var blob_dir = try tmp.dir.openDir(io, "blobs", .{ .iterate = true });
    defer blob_dir.close(io);
    var iterator = blob_dir.iterate();
    var file_count: usize = 0;
    while (try iterator.next(io)) |entry| {
        try testing.expect(!std.mem.endsWith(u8, entry.name, ".partial"));
        file_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), file_count);
}

test "blob write temps are writer-unique, so concurrent recorders never share one" {
    // Two writes of the same blob into the same directory agree on
    // every name component except the token: dir (shared layout), name
    // (the content hash). A temp built without the token would be ONE
    // file both writers truncate mid-write and rename out from under
    // each other — the loser's rename fails and a correct recording is
    // refused. The token carries the whole uniqueness, so this pin
    // fails if it ever leaves the name.
    var first_buffer: [256]u8 = undefined;
    var second_buffer: [256]u8 = undefined;
    const name = "aabbccddeeff00112233445566778899";
    const first = try blobPartialPath(&first_buffer, "session/blobs", name, 0x1111);
    const second = try blobPartialPath(&second_buffer, "session/blobs", name, 0x2222);
    try testing.expect(!std.mem.eql(u8, first, second));
    // Both stay recognizable install debris beside their blob.
    try testing.expect(std.mem.startsWith(u8, first, "session/blobs/aabbccddeeff00112233445566778899."));
    try testing.expect(std.mem.endsWith(u8, first, ".partial"));
    try testing.expect(std.mem.endsWith(u8, second, ".partial"));
}

test "a losing writer's failed rename succeeds through the content-addressed grace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buffer: [256]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path[0..]});
    var winner = try DirBlobStore.init(io, dir_path);
    var loser = try DirBlobStore.init(io, dir_path);

    const bytes = "encoded image bytes";
    const hash = hashBytes(bytes);
    const name = hexName(hash);
    var blob_path_buffer: [512]u8 = undefined;
    const blob_path = try std.fmt.bufPrint(&blob_path_buffer, "{s}/{s}", .{ dir_path, name });
    var partial_buffer: [512]u8 = undefined;
    const partial_path = try blobPartialPath(&partial_buffer, dir_path, &name, 0xdead);

    // The loser's exact state at the rename boundary, staged directly
    // (one `write` call cannot be paused mid-window, so the window is
    // pinned at the install seam): its probe saw the address ABSENT,
    // the winner then installed the addressed bytes, and the loser's
    // rename fails (here: the temp is gone — the shared-name theft this
    // fix's unique tokens prevent, and the one rename failure POSIX
    // makes deterministic). The bytes ARE durable under their address,
    // so the write must report success, not refuse a correct recording.
    try winner.write(hash, bytes);
    try loser.installPartial(partial_path, blob_path, bytes);
    var read_buffer: [4096]u8 = undefined;
    try testing.expectEqualStrings(bytes, try loser.read(hash, &read_buffer));

    // The grace VERIFIES: an address occupied by different bytes means
    // the write's bytes are NOT durable — that stays BlobIoFailed
    // (write's earlier repair path handles mismatches while the rename
    // can still deliver; here it cannot).
    const other = "different bytes at the same staged path";
    try testing.expectError(error.BlobIoFailed, loser.installPartial(partial_path, blob_path, other));

    // ...and an absent address after a failed rename is a plain failed
    // write.
    var absent_path_buffer: [512]u8 = undefined;
    const absent_name = hexName(hashBytes(other));
    const absent_path = try std.fmt.bufPrint(&absent_path_buffer, "{s}/{s}", .{ dir_path, absent_name });
    var absent_partial_buffer: [512]u8 = undefined;
    const absent_partial = try blobPartialPath(&absent_partial_buffer, dir_path, &absent_name, 0xbeef);
    try testing.expectError(error.BlobIoFailed, loser.installPartial(absent_partial, absent_path, other));

    // No temp debris outlives any of it.
    var blob_dir = try tmp.dir.openDir(io, "blobs", .{ .iterate = true });
    defer blob_dir.close(io);
    var iterator = blob_dir.iterate();
    var file_count: usize = 0;
    while (try iterator.next(io)) |entry| {
        try testing.expect(!std.mem.endsWith(u8, entry.name, ".partial"));
        file_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), file_count);
}

test "dir store verifies the dedup probe and repairs a damaged blob in place" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buffer: [256]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path[0..]});
    var store = try DirBlobStore.init(io, dir_path);

    const bytes = "encoded image bytes";
    const hash = hashBytes(bytes);
    const name = hexName(hash);
    var path_buffer: [300]u8 = undefined;
    const rel = try std.fmt.bufPrint(&path_buffer, "blobs/{s}", .{name});
    try store.write(hash, bytes);

    // Flip one byte on disk: the blob's name lies about its content.
    // Without the true bytes in hand this is replay's BlobCorrupt; the
    // next same-bytes RECORDING has them, so the dedup probe detects
    // the mismatch and repairs in place instead of sealing a journal
    // replay must refuse.
    var damaged: [64]u8 = undefined;
    @memcpy(damaged[0..bytes.len], bytes);
    damaged[3] ^= 0x40;
    try tmp.dir.writeFile(io, .{ .sub_path = rel, .data = damaged[0..bytes.len] });
    var read_buffer: [4096]u8 = undefined;
    try testing.expectError(error.BlobCorrupt, store.read(hash, &read_buffer));
    try store.write(hash, bytes);
    try testing.expectEqualStrings(bytes, try store.read(hash, &read_buffer));

    // A truncated blob (a different length, not just different bytes)
    // repairs the same way.
    try tmp.dir.writeFile(io, .{ .sub_path = rel, .data = bytes[0 .. bytes.len - 3] });
    try store.write(hash, bytes);
    try testing.expectEqualStrings(bytes, try store.read(hash, &read_buffer));

    // The repair went through the atomic partial+rename path: exactly
    // one blob file, no .partial debris.
    var blob_dir = try tmp.dir.openDir(io, "blobs", .{ .iterate = true });
    defer blob_dir.close(io);
    var iterator = blob_dir.iterate();
    var file_count: usize = 0;
    while (try iterator.next(io)) |entry| {
        try testing.expect(!std.mem.endsWith(u8, entry.name, ".partial"));
        file_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), file_count);
}
