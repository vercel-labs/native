const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;

pub const max_envelope_bytes: usize = 64 * 1024;
pub const max_payload_bytes: usize = 32 * 1024;
pub const max_release_notes_bytes: usize = 16 * 1024;
pub const max_archive_url_bytes: usize = 4096;
pub const max_archive_bytes: u64 = 8 * 1024 * 1024 * 1024;

pub const Envelope = struct {
    payload: []const u8,
    signature: []const u8,
};

pub const Release = struct {
    bundle_id: []const u8,
    version: []const u8,
    target: []const u8,
    archive_url: []const u8,
    archive_bytes: u64,
    sha256: []const u8,
    release_notes: []const u8 = "",
};

pub const VerifiedRelease = struct {
    payload: []u8,
    parsed: std.json.Parsed(Release),
    release: Release,

    pub fn deinit(self: *VerifiedRelease, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.payload);
    }
};

pub fn verifyEnvelope(
    allocator: std.mem.Allocator,
    envelope_bytes: []const u8,
    public_key_base64: []const u8,
) !VerifiedRelease {
    if (envelope_bytes.len == 0 or envelope_bytes.len > max_envelope_bytes) return error.InvalidUpdateFeed;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const envelope = std.json.parseFromSliceLeaky(Envelope, arena.allocator(), envelope_bytes, .{ .ignore_unknown_fields = false }) catch return error.InvalidUpdateFeed;

    const payload_size = std.base64.standard.Decoder.calcSizeForSlice(envelope.payload) catch return error.InvalidUpdateFeed;
    if (payload_size == 0 or payload_size > max_payload_bytes) return error.InvalidUpdateFeed;
    const payload = try allocator.alloc(u8, payload_size);
    errdefer allocator.free(payload);
    std.base64.standard.Decoder.decode(payload, envelope.payload) catch return error.InvalidUpdateFeed;

    var signature_bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    const signature_size = std.base64.standard.Decoder.calcSizeForSlice(envelope.signature) catch return error.InvalidUpdateSignature;
    if (signature_size != signature_bytes.len) return error.InvalidUpdateSignature;
    std.base64.standard.Decoder.decode(&signature_bytes, envelope.signature) catch return error.InvalidUpdateSignature;

    var public_key_bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    const public_key_size = std.base64.standard.Decoder.calcSizeForSlice(public_key_base64) catch return error.InvalidUpdateKey;
    if (public_key_size != public_key_bytes.len) return error.InvalidUpdateKey;
    std.base64.standard.Decoder.decode(&public_key_bytes, public_key_base64) catch return error.InvalidUpdateKey;
    const public_key = Ed25519.PublicKey.fromBytes(public_key_bytes) catch return error.InvalidUpdateKey;
    const signature = Ed25519.Signature.fromBytes(signature_bytes);
    signature.verifyStrict(payload, public_key) catch return error.InvalidUpdateSignature;

    var parsed = std.json.parseFromSlice(Release, allocator, payload, .{ .ignore_unknown_fields = false }) catch return error.InvalidUpdatePayload;
    errdefer parsed.deinit();
    try validateRelease(parsed.value);
    return .{
        .payload = payload,
        .release = parsed.value,
        .parsed = parsed,
    };
}

pub fn validateRelease(release: Release) !void {
    if (release.bundle_id.len == 0 or release.bundle_id.len > 128) return error.InvalidUpdatePayload;
    _ = try parseVersion(release.version);
    if (!std.mem.eql(u8, release.target, "macos-aarch64") and !std.mem.eql(u8, release.target, "macos-x86_64")) return error.InvalidUpdatePayload;
    if (!archiveUrlIsValid(release.archive_url)) return error.InvalidUpdatePayload;
    if (release.archive_bytes == 0 or release.archive_bytes > max_archive_bytes) return error.InvalidUpdatePayload;
    if (release.sha256.len != 64) return error.InvalidUpdatePayload;
    for (release.sha256) |byte| if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return error.InvalidUpdatePayload;
    if (release.release_notes.len > max_release_notes_bytes) return error.InvalidUpdatePayload;
}

pub fn archiveUrlIsValid(value: []const u8) bool {
    if (value.len == 0 or value.len > max_archive_url_bytes) return false;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f) return false;
    const uri = std.Uri.parse(value) catch return false;
    return std.mem.eql(u8, uri.scheme, "https") and uri.host != null and !uri.host.?.isEmpty();
}

pub fn releaseApplies(release: Release, bundle_id: []const u8, current_version: []const u8, target: []const u8) !bool {
    if (!std.mem.eql(u8, release.bundle_id, bundle_id)) return error.UpdateBundleMismatch;
    if (!std.mem.eql(u8, release.target, target)) return error.UpdateTargetMismatch;
    return try versionOrder(current_version, release.version) == .lt;
}

pub fn versionOrder(left: []const u8, right: []const u8) !std.math.Order {
    const left_version = try parseVersion(left);
    const right_version = try parseVersion(right);
    const major = std.math.order(left_version.major, right_version.major);
    if (major != .eq) return major;
    const minor = std.math.order(left_version.minor, right_version.minor);
    if (minor != .eq) return minor;
    return std.math.order(left_version.patch, right_version.patch);
}

pub fn archiveHashMatches(bytes: []const u8, expected_hex: []const u8) bool {
    if (expected_hex.len != std.crypto.hash.sha2.Sha256.digest_length * 2) return false;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    return std.crypto.timing_safe.eql([actual.len]u8, actual, expected_hex[0..actual.len].*);
}

const Version = struct { major: u64, minor: u64, patch: u64 };

fn parseVersion(value: []const u8) !Version {
    var parts = std.mem.splitScalar(u8, value, '.');
    const major = try parseVersionPart(parts.next() orelse return error.InvalidVersion);
    const minor = try parseVersionPart(parts.next() orelse return error.InvalidVersion);
    const patch = try parseVersionPart(parts.next() orelse return error.InvalidVersion);
    if (parts.next() != null) return error.InvalidVersion;
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn parseVersionPart(value: []const u8) !u64 {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return error.InvalidVersion;
    return std.fmt.parseUnsigned(u64, value, 10) catch error.InvalidVersion;
}

test "signed envelope verifies and yields its release" {
    const allocator = std.testing.allocator;
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** Ed25519.KeyPair.seed_length);
    const payload =
        \\{"bundle_id":"com.example.demo","version":"1.2.3","target":"macos-aarch64","archive_url":"https://example.com/demo.tar.gz","archive_bytes":42,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","release_notes":"Better."}
    ;
    const signature = try key_pair.sign(payload, null);
    var payload_base64: [std.base64.standard.Encoder.calcSize(payload.len)]u8 = undefined;
    var signature_base64: [std.base64.standard.Encoder.calcSize(Ed25519.Signature.encoded_length)]u8 = undefined;
    var public_key_base64: [std.base64.standard.Encoder.calcSize(Ed25519.PublicKey.encoded_length)]u8 = undefined;
    const envelope = try std.fmt.allocPrint(allocator, "{{\"payload\":\"{s}\",\"signature\":\"{s}\"}}", .{
        std.base64.standard.Encoder.encode(&payload_base64, payload),
        std.base64.standard.Encoder.encode(&signature_base64, &signature.toBytes()),
    });
    defer allocator.free(envelope);
    const public_key = std.base64.standard.Encoder.encode(&public_key_base64, &key_pair.public_key.toBytes());
    var verified = try verifyEnvelope(allocator, envelope, public_key);
    defer verified.deinit(allocator);
    try std.testing.expectEqualStrings("1.2.3", verified.release.version);
    try std.testing.expect(try releaseApplies(verified.release, "com.example.demo", "1.2.2", "macos-aarch64"));
}

test "tampered payload is rejected" {
    const allocator = std.testing.allocator;
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{0x24} ** Ed25519.KeyPair.seed_length);
    const payload = "{}";
    const signature = try key_pair.sign(payload, null);
    var signature_base64: [std.base64.standard.Encoder.calcSize(Ed25519.Signature.encoded_length)]u8 = undefined;
    var public_key_base64: [std.base64.standard.Encoder.calcSize(Ed25519.PublicKey.encoded_length)]u8 = undefined;
    const envelope = try std.fmt.allocPrint(allocator, "{{\"payload\":\"eyJhIjoxfQ==\",\"signature\":\"{s}\"}}", .{
        std.base64.standard.Encoder.encode(&signature_base64, &signature.toBytes()),
    });
    defer allocator.free(envelope);
    const public_key = std.base64.standard.Encoder.encode(&public_key_base64, &key_pair.public_key.toBytes());
    try std.testing.expectError(error.InvalidUpdateSignature, verifyEnvelope(allocator, envelope, public_key));
}

test "semantic versions compare numerically" {
    try std.testing.expectEqual(std.math.Order.lt, try versionOrder("1.9.9", "1.10.0"));
    try std.testing.expectEqual(std.math.Order.eq, try versionOrder("2.0.0", "2.0.0"));
    try std.testing.expectEqual(std.math.Order.gt, try versionOrder("3.0.0", "2.99.99"));
    try std.testing.expectError(error.InvalidVersion, versionOrder("1.010.0", "1.9.0"));
    try std.testing.expectError(error.InvalidVersion, versionOrder("1.9.0", "1.010.0"));
    try std.testing.expectError(error.InvalidVersion, releaseApplies(.{
        .bundle_id = "com.example.demo",
        .version = "1.9.0",
        .target = "macos-aarch64",
        .archive_url = "https://example.com/demo.zip",
        .archive_bytes = 42,
        .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }, "com.example.demo", "1.010.0", "macos-aarch64"));
}

test "archive URLs fit the runtime output buffer" {
    var maximum: [max_archive_url_bytes]u8 = [_]u8{'a'} ** max_archive_url_bytes;
    @memcpy(maximum[0.."https://".len], "https://");
    try validateRelease(.{
        .bundle_id = "com.example.demo",
        .version = "1.2.3",
        .target = "macos-aarch64",
        .archive_url = &maximum,
        .archive_bytes = 42,
        .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    });

    var oversized: [max_archive_url_bytes + 1]u8 = [_]u8{'a'} ** (max_archive_url_bytes + 1);
    @memcpy(oversized[0.."https://".len], "https://");
    try std.testing.expectError(error.InvalidUpdatePayload, validateRelease(.{
        .bundle_id = "com.example.demo",
        .version = "1.2.3",
        .target = "macos-aarch64",
        .archive_url = &oversized,
        .archive_bytes = 42,
        .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }));

    try std.testing.expect(!archiveUrlIsValid("https://"));
    try std.testing.expect(!archiveUrlIsValid("https://example.com/release file.zip"));
    try std.testing.expect(!archiveUrlIsValid("https://example.com/release.zip\n"));
    try std.testing.expect(!archiveUrlIsValid("http://example.com/release.zip"));
    try std.testing.expect(archiveUrlIsValid("https://example.com/releases/demo.zip?channel=stable"));
}
