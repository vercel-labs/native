const std = @import("std");
const feed = @import("feed.zig");

pub const VerifyResult = extern struct {
    ok: c_int,
    error_code: c_int,
    version_len: usize,
    archive_url_len: usize,
    release_notes_len: usize,
    archive_bytes: u64,
    sha256: [64]u8,
};

pub export fn native_sdk_update_verify_feed(
    envelope_ptr: [*]const u8,
    envelope_len: usize,
    public_key_ptr: [*]const u8,
    public_key_len: usize,
    bundle_id_ptr: [*]const u8,
    bundle_id_len: usize,
    current_version_ptr: [*]const u8,
    current_version_len: usize,
    target_ptr: [*]const u8,
    target_len: usize,
    version_out: [*]u8,
    version_capacity: usize,
    archive_url_out: [*]u8,
    archive_url_capacity: usize,
    release_notes_out: [*]u8,
    release_notes_capacity: usize,
) callconv(.c) VerifyResult {
    var result: VerifyResult = .{
        .ok = 0,
        .error_code = 1,
        .version_len = 0,
        .archive_url_len = 0,
        .release_notes_len = 0,
        .archive_bytes = 0,
        .sha256 = [_]u8{0} ** 64,
    };
    var verified = feed.verifyEnvelope(
        std.heap.page_allocator,
        envelope_ptr[0..envelope_len],
        public_key_ptr[0..public_key_len],
    ) catch |err| {
        result.error_code = verifyErrorCode(err);
        return result;
    };
    defer verified.deinit(std.heap.page_allocator);
    const release = verified.release;
    const applies = feed.releaseApplies(
        release,
        bundle_id_ptr[0..bundle_id_len],
        current_version_ptr[0..current_version_len],
        target_ptr[0..target_len],
    ) catch |err| {
        result.error_code = verifyErrorCode(err);
        return result;
    };
    if (!applies) {
        result.ok = 2;
        result.error_code = 0;
        return result;
    }
    if (release.version.len > version_capacity or release.archive_url.len > archive_url_capacity or release.release_notes.len > release_notes_capacity) {
        result.error_code = 8;
        return result;
    }
    @memcpy(version_out[0..release.version.len], release.version);
    @memcpy(archive_url_out[0..release.archive_url.len], release.archive_url);
    @memcpy(release_notes_out[0..release.release_notes.len], release.release_notes);
    @memcpy(&result.sha256, release.sha256);
    result.ok = 1;
    result.error_code = 0;
    result.version_len = release.version.len;
    result.archive_url_len = release.archive_url.len;
    result.release_notes_len = release.release_notes.len;
    result.archive_bytes = release.archive_bytes;
    return result;
}

pub export fn native_sdk_update_verify_archive(
    path_ptr: [*]const u8,
    path_len: usize,
    expected_bytes: u64,
    sha256_ptr: [*]const u8,
    sha256_len: usize,
) callconv(.c) c_int {
    if (path_len == 0 or sha256_len != 64) return 0;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = path_ptr[0..path_len];
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer file.close(io);
    const stat = file.stat(io) catch return 0;
    if (stat.size != expected_bytes) return 0;
    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const count = reader.interface.readSliceShort(&chunk) catch return 0;
        if (count == 0) break;
        hasher.update(chunk[0..count]);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const actual = std.fmt.bytesToHex(digest, .lower);
    return if (std.crypto.timing_safe.eql([64]u8, actual, sha256_ptr[0..64].*)) 1 else 0;
}

fn verifyErrorCode(err: anyerror) c_int {
    return switch (err) {
        error.InvalidUpdateKey => 2,
        error.InvalidUpdateSignature => 3,
        error.InvalidUpdatePayload, error.InvalidUpdateFeed => 4,
        error.UpdateBundleMismatch => 5,
        error.UpdateTargetMismatch => 6,
        error.OutOfMemory => 7,
        else => 1,
    };
}
