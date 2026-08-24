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
    if (!update_feed.archiveUrlIsValid(url)) return error.InvalidArchiveUrl;
    if (!std.mem.eql(u8, release_target, "macos-aarch64") and !std.mem.eql(u8, release_target, "macos-x86_64")) return error.InvalidTarget;
    if (!std.mem.endsWith(u8, archive, ".zip")) return error.InvalidArchive;
    const metadata = try manifest_tool.readMetadata(allocator, io, manifest_path orelse manifest_tool.defaultPath(io) orelse "app.json");
    defer metadata.deinit(allocator);
    if (!metadata.updates.enabled()) return error.UpdatesNotConfigured;
    if (release_notes.len > 16 * 1024) return error.ReleaseNotesTooLarge;
    validateUpdateArchive(allocator, io, archive, metadata.id, metadata.version, metadata.name) catch return error.InvalidArchive;

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
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, output_path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, output_writer.written());
    try atomic.replace(io);
    std.debug.print("signed {s} {s} update ({d} bytes) into {s}\n", .{ metadata.displayName(), metadata.version, archive_stat.size, output_path });
}

const max_info_plist_bytes: u64 = 1024 * 1024;

fn validateUpdateArchive(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    expected_bundle_id: []const u8,
    expected_version: []const u8,
    expected_executable: []const u8,
) !void {
    var file = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
    defer file.close(io);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var iterator = try std.zip.Iterator.init(&reader);
    var filename_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var app_root: ?[]u8 = null;
    defer if (app_root) |root| allocator.free(root);
    var info_plist: ?[]u8 = null;
    defer if (info_plist) |plist| allocator.free(plist);
    var executable_count: usize = 0;
    var meaningful_entries: usize = 0;

    while (try iterator.next()) |entry| {
        const filename = try zipEntryFilename(&reader, entry, &filename_buffer);
        if (!zipEntryPathIsSafe(filename)) return error.InvalidArchive;
        if (std.mem.eql(u8, filename, "__MACOSX") or std.mem.startsWith(u8, filename, "__MACOSX/")) continue;
        meaningful_entries += 1;
        if (meaningful_entries > 1_000_000) return error.InvalidArchive;

        const separator = std.mem.indexOfScalar(u8, filename, '/') orelse filename.len;
        if (separator == filename.len) return error.InvalidArchive;
        const root = filename[0..separator];
        if (root.len < ".app".len or !std.ascii.eqlIgnoreCase(root[root.len - ".app".len ..], ".app")) return error.InvalidArchive;
        if (app_root) |existing| {
            if (!std.mem.eql(u8, existing, root)) return error.InvalidArchive;
        } else {
            app_root = try allocator.dupe(u8, root);
        }

        const plist_suffix = "/Contents/Info.plist";
        if (filename.len == root.len + plist_suffix.len and
            std.mem.eql(u8, filename[root.len..], plist_suffix))
        {
            if (info_plist != null) return error.InvalidArchive;
            info_plist = try readZipEntryAlloc(allocator, &reader, entry, filename, max_info_plist_bytes);
        }
        const executable_prefix = "/Contents/MacOS/";
        if (filename.len == root.len + executable_prefix.len + expected_executable.len and
            std.mem.eql(u8, filename[root.len .. root.len + executable_prefix.len], executable_prefix) and
            std.mem.eql(u8, filename[root.len + executable_prefix.len ..], expected_executable))
        {
            if (entry.uncompressed_size == 0) return error.InvalidArchive;
            executable_count += 1;
        }
    }

    if (meaningful_entries == 0 or app_root == null or executable_count != 1) return error.InvalidArchive;
    const plist = info_plist orelse return error.InvalidArchive;
    if (!plistStringValueEquals(plist, "CFBundleIdentifier", expected_bundle_id) or
        !plistStringValueEquals(plist, "CFBundleVersion", expected_version) or
        !plistStringValueEquals(plist, "CFBundleExecutable", expected_executable) or
        !plistStringValueEquals(plist, "CFBundlePackageType", "APPL")) return error.InvalidArchive;
}

fn zipEntryFilename(reader: *std.Io.File.Reader, entry: std.zip.Iterator.Entry, buffer: []u8) ![]const u8 {
    const filename_len = std.math.cast(usize, entry.filename_len) orelse return error.InvalidArchive;
    if (filename_len == 0 or filename_len > buffer.len) return error.InvalidArchive;
    try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
    try reader.interface.readSliceAll(buffer[0..filename_len]);
    return buffer[0..filename_len];
}

fn zipEntryPathIsSafe(filename: []const u8) bool {
    if (filename.len == 0 or filename[0] == '/' or std.mem.indexOf(u8, filename, "//") != null or std.mem.indexOfScalar(u8, filename, '\\') != null or std.mem.indexOfScalar(u8, filename, 0) != null) return false;
    var segments = std.mem.splitScalar(u8, filename, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

fn readZipEntryAlloc(
    allocator: std.mem.Allocator,
    reader: *std.Io.File.Reader,
    entry: std.zip.Iterator.Entry,
    expected_filename: []const u8,
    max_uncompressed_bytes: u64,
) ![]u8 {
    if (entry.uncompressed_size == 0 or entry.uncompressed_size > max_uncompressed_bytes) return error.InvalidArchive;
    const output_len = std.math.cast(usize, entry.uncompressed_size) orelse return error.InvalidArchive;
    const compressed_len = std.math.cast(usize, entry.compressed_size) orelse return error.InvalidArchive;
    if (compressed_len == 0) return error.InvalidArchive;

    var local_header: [@sizeOf(std.zip.LocalFileHeader)]u8 = undefined;
    try reader.seekTo(entry.file_offset);
    try reader.interface.readSliceAll(&local_header);
    if (!std.mem.eql(u8, local_header[0..4], &std.zip.local_file_header_sig)) return error.InvalidArchive;
    const flags = std.mem.readInt(u16, local_header[6..8], .little);
    if (flags & 1 != 0) return error.InvalidArchive;
    const method = std.mem.readInt(u16, local_header[8..10], .little);
    if (method != @intFromEnum(entry.compression_method)) return error.InvalidArchive;
    const local_crc = std.mem.readInt(u32, local_header[14..18], .little);
    if (local_crc != 0 and local_crc != entry.crc32) return error.InvalidArchive;
    const filename_len = std.mem.readInt(u16, local_header[26..28], .little);
    const extra_len = std.mem.readInt(u16, local_header[28..30], .little);
    if (filename_len != expected_filename.len) return error.InvalidArchive;
    var local_filename: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (filename_len > local_filename.len) return error.InvalidArchive;
    try reader.interface.readSliceAll(local_filename[0..filename_len]);
    if (!std.mem.eql(u8, local_filename[0..filename_len], expected_filename)) return error.InvalidArchive;
    try reader.seekTo(entry.file_offset + @sizeOf(std.zip.LocalFileHeader) + filename_len + extra_len);

    const output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);
    var limited_buffer: [4096]u8 = undefined;
    var limited = reader.interface.limited(.limited(compressed_len), &limited_buffer);
    switch (entry.compression_method) {
        .store => {
            if (entry.compressed_size != entry.uncompressed_size) return error.InvalidArchive;
            try limited.interface.readSliceAll(output);
        },
        .deflate => {
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress = std.compress.flate.Decompress.init(&limited.interface, .raw, &window);
            try decompress.reader.readSliceAll(output);
            var extra: [1]u8 = undefined;
            if ((decompress.reader.readSliceShort(&extra) catch 0) != 0) return error.InvalidArchive;
        },
        else => return error.InvalidArchive,
    }
    if (limited.remaining != .nothing) return error.InvalidArchive;
    if (std.hash.Crc32.hash(output) != entry.crc32) return error.InvalidArchive;
    return output;
}

fn plistStringValueEquals(plist: []const u8, key: []const u8, expected: []const u8) bool {
    var key_buffer: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&key_buffer, "<key>{s}</key>", .{key}) catch return false;
    const key_at = std.mem.indexOf(u8, plist, needle) orelse return false;
    const after_key = plist[key_at + needle.len ..];
    const string_at = std.mem.trimStart(u8, after_key, " \t\r\n");
    if (!std.mem.startsWith(u8, string_at, "<string>")) return false;
    const value_start = "<string>".len;
    const value_tail = string_at[value_start..];
    const value_end = std.mem.indexOf(u8, value_tail, "</string>") orelse return false;
    const encoded = value_tail[0..value_end];
    var encoded_index: usize = 0;
    var expected_index: usize = 0;
    while (encoded_index < encoded.len and expected_index < expected.len) {
        const decoded: u8 = if (encoded[encoded_index] == '&') entity: {
            for ([_]struct { entity: []const u8, value: u8 }{
                .{ .entity = "&amp;", .value = '&' },
                .{ .entity = "&lt;", .value = '<' },
                .{ .entity = "&gt;", .value = '>' },
                .{ .entity = "&quot;", .value = '"' },
                .{ .entity = "&apos;", .value = '\'' },
            }) |candidate| {
                if (std.mem.startsWith(u8, encoded[encoded_index..], candidate.entity)) {
                    encoded_index += candidate.entity.len;
                    break :entity candidate.value;
                }
            }
            return false;
        } else plain: {
            const value = encoded[encoded_index];
            encoded_index += 1;
            break :plain value;
        };
        if (decoded != expected[expected_index]) return false;
        expected_index += 1;
    }
    return encoded_index == encoded.len and expected_index == expected.len;
}

test "generated key is private and public key is derivable" {
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{0x61} ** Ed25519.KeyPair.seed_length);
    const recovered = try Ed25519.KeyPair.generateDeterministic(key_pair.secret_key.seed());
    try std.testing.expectEqualSlices(u8, &key_pair.public_key.toBytes(), &recovered.public_key.toBytes());
}

const StoredZipEntry = struct {
    name: []const u8,
    data: []const u8,
};

fn storedZipAlloc(allocator: std.mem.Allocator, entries: []const StoredZipEntry) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    const offsets = try allocator.alloc(u32, entries.len);
    defer allocator.free(offsets);

    for (entries, 0..) |entry, index| {
        offsets[index] = @intCast(output.written().len);
        const crc = std.hash.Crc32.hash(entry.data);
        try writer.writeAll(&std.zip.local_file_header_sig);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, @intFromEnum(std.zip.CompressionMethod.store), .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, crc, .little);
        try writer.writeInt(u32, @intCast(entry.data.len), .little);
        try writer.writeInt(u32, @intCast(entry.data.len), .little);
        try writer.writeInt(u16, @intCast(entry.name.len), .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeAll(entry.name);
        try writer.writeAll(entry.data);
    }

    const central_offset: u32 = @intCast(output.written().len);
    for (entries, 0..) |entry, index| {
        const crc = std.hash.Crc32.hash(entry.data);
        try writer.writeAll(&std.zip.central_file_header_sig);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, @intFromEnum(std.zip.CompressionMethod.store), .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, crc, .little);
        try writer.writeInt(u32, @intCast(entry.data.len), .little);
        try writer.writeInt(u32, @intCast(entry.data.len), .little);
        try writer.writeInt(u16, @intCast(entry.name.len), .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, 0, .little);
        try writer.writeInt(u32, offsets[index], .little);
        try writer.writeAll(entry.name);
    }
    const central_size: u32 = @intCast(output.written().len - central_offset);
    try writer.writeAll(&std.zip.end_record_sig);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, @intCast(entries.len), .little);
    try writer.writeInt(u16, @intCast(entries.len), .little);
    try writer.writeInt(u32, central_size, .little);
    try writer.writeInt(u32, central_offset, .little);
    try writer.writeInt(u16, 0, .little);
    return output.toOwnedSlice();
}

fn updateInfoPlist(bundle_id: []const u8, version: []const u8, executable: []const u8, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<plist version="1.0"><dict>
        \\<key>CFBundleIdentifier</key><string>{s}</string>
        \\<key>CFBundleVersion</key><string>{s}</string>
        \\<key>CFBundleExecutable</key><string>{s}</string>
        \\<key>CFBundlePackageType</key><string>APPL</string>
        \\</dict></plist>
    , .{ bundle_id, version, executable });
}

test "update archive validation requires one matching app bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var plist_buffer: [1024]u8 = undefined;
    const plist = try updateInfoPlist("com.example.demo", "1.2.3", "demo", &plist_buffer);
    const valid_entries = [_]StoredZipEntry{
        .{ .name = "Demo.app/Contents/Info.plist", .data = plist },
        .{ .name = "Demo.app/Contents/MacOS/demo", .data = "binary" },
        .{ .name = "__MACOSX/Demo.app/Contents/._Info.plist", .data = "metadata" },
    };
    const valid_zip = try storedZipAlloc(std.testing.allocator, &valid_entries);
    defer std.testing.allocator.free(valid_zip);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "valid.zip", .data = valid_zip });
    const valid_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/valid.zip", .{tmp.sub_path});
    defer std.testing.allocator.free(valid_path);
    try validateUpdateArchive(std.testing.allocator, std.testing.io, valid_path, "com.example.demo", "1.2.3", "demo");

    const extra_root_entries = [_]StoredZipEntry{
        .{ .name = "Demo.app/Contents/Info.plist", .data = plist },
        .{ .name = "Demo.app/Contents/MacOS/demo", .data = "binary" },
        .{ .name = "README.txt", .data = "unexpected" },
    };
    const invalid_zip = try storedZipAlloc(std.testing.allocator, &extra_root_entries);
    defer std.testing.allocator.free(invalid_zip);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "invalid.zip", .data = invalid_zip });
    const invalid_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/invalid.zip", .{tmp.sub_path});
    defer std.testing.allocator.free(invalid_path);
    try std.testing.expectError(error.InvalidArchive, validateUpdateArchive(std.testing.allocator, std.testing.io, invalid_path, "com.example.demo", "1.2.3", "demo"));
    try std.testing.expectError(error.InvalidArchive, validateUpdateArchive(std.testing.allocator, std.testing.io, valid_path, "com.example.other", "1.2.3", "demo"));
    try std.testing.expectError(error.InvalidArchive, validateUpdateArchive(std.testing.allocator, std.testing.io, valid_path, "com.example.demo", "1.2.4", "demo"));
}
