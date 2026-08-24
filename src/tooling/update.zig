const std = @import("std");
const manifest_tool = @import("manifest.zig");
const update_feed = @import("update_feed");

const Ed25519 = std.crypto.sign.Ed25519;

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len == 0) return error.InvalidArguments;
    if (std.mem.eql(u8, args[0], "keygen")) return keygen(allocator, io, args[1..]);
    if (std.mem.eql(u8, args[0], "sign")) return sign(allocator, io, args[1..]);
    return error.InvalidArguments;
}

fn keygen(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var private_path: []const u8 = "native-update.key";
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--private-key")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            private_path = args[index];
        } else return error.InvalidArguments;
    }
    const existing = std.Io.Dir.cwd().openFile(io, private_path, .{}) catch null;
    if (existing) |file| {
        file.close(io);
        return error.KeyAlreadyExists;
    }
    const key_pair = Ed25519.KeyPair.generate(io);
    const seed = key_pair.secret_key.seed();
    const private_permissions: std.Io.File.Permissions = if (std.Io.File.Permissions.has_executable_bit) .fromMode(0o600) else .default_file;
    var file = try std.Io.Dir.cwd().createFile(io, private_path, .{ .exclusive = true, .permissions = private_permissions });
    defer file.close(io);
    try file.writeStreamingAll(io, &seed);
    var public_key_base64: [std.base64.standard.Encoder.calcSize(Ed25519.PublicKey.encoded_length)]u8 = undefined;
    const public_key = std.base64.standard.Encoder.encode(&public_key_base64, &key_pair.public_key.toBytes());
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout_writer.interface.print("{s}\n", .{public_key});
    try stdout_writer.interface.flush();
    std.debug.print("generated private update key at {s}{s}; store it outside the app and back it up securely\n", .{ private_path, if (std.Io.File.Permissions.has_executable_bit) " (mode 0600)" else "" });
    _ = allocator;
}

fn sign(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var private_path: []const u8 = "native-update.key";
    var manifest_path: ?[]const u8 = null;
    var archive_path: ?[]const u8 = null;
    var archive_url: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var release_notes: []const u8 = "";
    var output_path: []const u8 = "native-update.json";
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const name = args[index];
        index += 1;
        if (index >= args.len) return error.InvalidArguments;
        const value = args[index];
        if (std.mem.eql(u8, name, "--private-key")) private_path = value else if (std.mem.eql(u8, name, "--manifest")) manifest_path = value else if (std.mem.eql(u8, name, "--archive")) archive_path = value else if (std.mem.eql(u8, name, "--url")) archive_url = value else if (std.mem.eql(u8, name, "--target")) target = value else if (std.mem.eql(u8, name, "--notes")) release_notes = value else if (std.mem.eql(u8, name, "--output")) output_path = value else return error.InvalidArguments;
    }
    const archive = archive_path orelse return error.InvalidArguments;
    const url = archive_url orelse return error.InvalidArguments;
    const release_target = target orelse return error.InvalidArguments;
    if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidArchiveUrl;
    if (!std.mem.eql(u8, release_target, "macos-aarch64") and !std.mem.eql(u8, release_target, "macos-x86_64")) return error.InvalidTarget;
    if (!std.mem.endsWith(u8, archive, ".zip")) return error.InvalidArchive;
    const metadata = try manifest_tool.readMetadata(allocator, io, manifest_path orelse manifest_tool.defaultPath(io) orelse "app.json");
    defer metadata.deinit(allocator);
    if (!metadata.updates.enabled()) return error.UpdatesNotConfigured;
    if (release_notes.len > 16 * 1024) return error.ReleaseNotesTooLarge;

    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    var key_file = try std.Io.Dir.cwd().openFile(io, private_path, .{});
    defer key_file.close(io);
    var key_reader_buffer: [64]u8 = undefined;
    var key_reader = key_file.reader(io, &key_reader_buffer);
    try key_reader.interface.readSliceAll(&seed);
    var extra: [1]u8 = undefined;
    if (try key_reader.interface.readSliceShort(&extra) != 0) return error.InvalidPrivateKey;
    const key_pair = try Ed25519.KeyPair.generateDeterministic(seed);
    const configured_public_key = metadata.updates.public_key orelse return error.UpdatesNotConfigured;
    var configured_public_key_bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    const configured_public_key_size = std.base64.standard.Decoder.calcSizeForSlice(configured_public_key) catch return error.InvalidUpdatePublicKey;
    if (configured_public_key_size != configured_public_key_bytes.len) return error.InvalidUpdatePublicKey;
    std.base64.standard.Decoder.decode(&configured_public_key_bytes, configured_public_key) catch return error.InvalidUpdatePublicKey;
    if (!std.crypto.timing_safe.eql([Ed25519.PublicKey.encoded_length]u8, key_pair.public_key.toBytes(), configured_public_key_bytes)) return error.UpdateKeyMismatch;

    var archive_file = try std.Io.Dir.cwd().openFile(io, archive, .{});
    defer archive_file.close(io);
    const archive_stat = try archive_file.stat(io);
    if (archive_stat.size == 0 or archive_stat.size > update_feed.max_archive_bytes) return error.InvalidArchive;
    var archive_reader_buffer: [64 * 1024]u8 = undefined;
    var archive_reader = archive_file.reader(io, &archive_reader_buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try archive_reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        hasher.update(chunk[0..count]);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const sha256 = std.fmt.bytesToHex(digest, .lower);

    const Payload = struct {
        bundle_id: []const u8,
        version: []const u8,
        target: []const u8,
        archive_url: []const u8,
        archive_bytes: u64,
        sha256: []const u8,
        release_notes: []const u8,
    };
    var payload_writer = std.Io.Writer.Allocating.init(allocator);
    defer payload_writer.deinit();
    try std.json.Stringify.value(Payload{
        .bundle_id = metadata.id,
        .version = metadata.version,
        .target = release_target,
        .archive_url = url,
        .archive_bytes = archive_stat.size,
        .sha256 = &sha256,
        .release_notes = release_notes,
    }, .{}, &payload_writer.writer);
    const payload = payload_writer.written();
    const signature = try key_pair.sign(payload, null);
    const payload_size = std.base64.standard.Encoder.calcSize(payload.len);
    const payload_base64 = try allocator.alloc(u8, payload_size);
    defer allocator.free(payload_base64);
    var signature_base64: [std.base64.standard.Encoder.calcSize(Ed25519.Signature.encoded_length)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(payload_base64, payload);
    _ = std.base64.standard.Encoder.encode(&signature_base64, &signature.toBytes());
    var output_writer = std.Io.Writer.Allocating.init(allocator);
    defer output_writer.deinit();
    try std.json.Stringify.value(.{ .payload = payload_base64, .signature = &signature_base64 }, .{ .whitespace = .indent_2 }, &output_writer.writer);
    try output_writer.writer.writeByte('\n');
    var verified = try update_feed.verifyEnvelope(allocator, output_writer.written(), configured_public_key);
    defer verified.deinit(allocator);
    if (!std.mem.eql(u8, verified.release.bundle_id, metadata.id) or
        !std.mem.eql(u8, verified.release.version, metadata.version) or
        !std.mem.eql(u8, verified.release.target, release_target)) return error.GeneratedFeedInvalid;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = output_writer.written() });
    std.debug.print("signed {s} {s} update ({d} bytes) into {s}\n", .{ metadata.displayName(), metadata.version, archive_stat.size, output_path });
}

test "generated key is private and public key is derivable" {
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{0x61} ** Ed25519.KeyPair.seed_length);
    const recovered = try Ed25519.KeyPair.generateDeterministic(key_pair.secret_key.seed());
    try std.testing.expectEqualSlices(u8, &key_pair.public_key.toBytes(), &recovered.public_key.toBytes());
}
