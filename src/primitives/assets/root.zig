const std = @import("std");

pub const AssetKind = enum {
    unknown,
    image,
    font,
    text,
    json,
    binary,
    localization,
    audio,
    video,
};

pub const HashAlgorithm = enum {
    sha256,
};

pub const PathError = error{
    EmptyPath,
    AbsolutePath,
    EmptySegment,
    CurrentSegment,
    ParentSegment,
    NullByte,
    NoSpaceLeft,
};

pub const IdError = error{
    EmptyId,
    AbsoluteId,
    EmptySegment,
    CurrentSegment,
    ParentSegment,
    InvalidCharacter,
    NullByte,
};

pub const HashError = error{
    InvalidHashLength,
    InvalidHashCharacter,
};

pub const ManifestError = error{
    DuplicateId,
    DuplicateBundlePath,
    InvalidId,
    InvalidPath,
    MissingAsset,
    InvalidHash,
    UnsortedManifest,
};

pub const Hash = struct {
    pub const algorithm: HashAlgorithm = .sha256;
    pub const digest_len = 32;
    pub const hex_len = digest_len * 2;

    bytes: [digest_len]u8,

    pub fn init(bytes: [digest_len]u8) Hash {
        return .{ .bytes = bytes };
    }

    pub fn zero() Hash {
        return .{ .bytes = @splat(@as(u8, 0)) };
    }

    pub fn toHex(self: Hash) [hex_len]u8 {
        var out: [hex_len]u8 = undefined;
        for (self.bytes, 0..) |byte, i| {
            writeHexByte(&out, i * 2, byte);
        }
        return out;
    }

    pub fn parseHex(input: []const u8) HashError!Hash {
        if (input.len != hex_len) return error.InvalidHashLength;

        var bytes: [digest_len]u8 = undefined;
        for (&bytes, 0..) |*byte, i| {
            byte.* = try hexByte(input[i * 2], input[i * 2 + 1]);
        }
        return .{ .bytes = bytes };
    }

    pub fn eql(a: Hash, b: Hash) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

pub const AssetId = struct {
    value: []const u8,

    pub fn init(value: []const u8) IdError!AssetId {
        try validateId(value);
        return .{ .value = value };
    }
};

pub const AssetPath = struct {
    source: []const u8,
    bundle: []const u8,

    pub fn init(source: []const u8, bundle: []const u8) PathError!AssetPath {
        try validateNormalizedPath(source);
        try validateNormalizedPath(bundle);
        return .{ .source = source, .bundle = bundle };
    }
};

pub const Asset = struct {
    id: []const u8,
    kind: AssetKind = .unknown,
    source_path: []const u8,
    bundle_path: []const u8,
    byte_len: u64 = 0,
    hash: Hash = .zero(),
    media_type: ?[]const u8 = null,
};

pub const Manifest = struct {
    assets: []const Asset,

    pub fn validate(self: Manifest) ManifestError!void {
        for (self.assets, 0..) |asset, i| {
            validateId(asset.id) catch return error.InvalidId;
            validateNormalizedPath(asset.source_path) catch return error.InvalidPath;
            validateNormalizedPath(asset.bundle_path) catch return error.InvalidPath;

            if (i > 0) {
                const previous = self.assets[i - 1];
                const id_order = compareLex(previous.id, asset.id);
                if (id_order > 0 or (id_order == 0 and compareLex(previous.bundle_path, asset.bundle_path) > 0)) {
                    return error.UnsortedManifest;
                }
                if (std.mem.eql(u8, previous.id, asset.id)) {
                    return error.DuplicateId;
                }
            }

            for (self.assets[0..i]) |previous| {
                if (std.mem.eql(u8, previous.bundle_path, asset.bundle_path)) {
                    return error.DuplicateBundlePath;
                }
            }
        }
    }

    pub fn findById(self: Manifest, id: []const u8) ?Asset {
        for (self.assets) |asset| {
            if (std.mem.eql(u8, asset.id, id)) return asset;
        }
        return null;
    }

    pub fn findByBundlePath(self: Manifest, bundle_path: []const u8) ?Asset {
        for (self.assets) |asset| {
            if (std.mem.eql(u8, asset.bundle_path, bundle_path)) return asset;
        }
        return null;
    }
};

pub fn sha256(bytes: []const u8) Hash {
    var digest: [Hash.digest_len]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .bytes = digest };
}

pub fn hashHex(bytes: []const u8) [Hash.hex_len]u8 {
    return sha256(bytes).toHex();
}

pub fn parseHashHex(input: []const u8) HashError!Hash {
    return Hash.parseHex(input);
}

pub fn normalizePath(output: []u8, input: []const u8) PathError![]const u8 {
    if (input.len == 0) return error.EmptyPath;
    if (isAbsolutePath(input)) return error.AbsolutePath;

    var out_len: usize = 0;
    var segment_start: usize = 0;

    for (input) |raw| {
        if (raw == 0) return error.NullByte;
        const ch: u8 = if (raw == '\\') '/' else raw;

        if (ch == '/') {
            try validateSegmentForPath(output[segment_start..out_len]);
            if (out_len >= output.len) return error.NoSpaceLeft;
            output[out_len] = '/';
            out_len += 1;
            segment_start = out_len;
            continue;
        }

        if (out_len >= output.len) return error.NoSpaceLeft;
        output[out_len] = ch;
        out_len += 1;
    }

    try validateSegmentForPath(output[segment_start..out_len]);
    return output[0..out_len];
}

pub fn validateId(id: []const u8) IdError!void {
    if (id.len == 0) return error.EmptyId;
    if (id[0] == '/') return error.AbsoluteId;

    var segment_start: usize = 0;
    var segment_len: usize = 0;

    for (id, 0..) |ch, i| {
        if (ch == 0) return error.NullByte;
        if (ch == '/') {
            try validateIdSegment(id[segment_start..i], segment_len);
            segment_start = i + 1;
            segment_len = 0;
            continue;
        }

        if (!isIdChar(ch)) return error.InvalidCharacter;
        segment_len += 1;
    }

    try validateIdSegment(id[segment_start..], segment_len);
}

pub fn inferKind(path: []const u8) AssetKind {
    const ext = extension(path) orelse return .unknown;
    if (extEql(ext, "png") or extEql(ext, "jpg") or extEql(ext, "jpeg") or extEql(ext, "webp") or extEql(ext, "gif") or extEql(ext, "svg") or extEql(ext, "bmp")) return .image;
    if (extEql(ext, "ttf") or extEql(ext, "otf") or extEql(ext, "woff") or extEql(ext, "woff2")) return .font;
    if (extEql(ext, "txt") or extEql(ext, "md") or extEql(ext, "csv")) return .text;
    if (extEql(ext, "json")) return .json;
    if (extEql(ext, "strings") or extEql(ext, "ftl") or extEql(ext, "po") or extEql(ext, "mo")) return .localization;
    if (extEql(ext, "mp3") or extEql(ext, "wav") or extEql(ext, "ogg") or extEql(ext, "flac") or extEql(ext, "m4a")) return .audio;
    if (extEql(ext, "mp4") or extEql(ext, "webm") or extEql(ext, "mov") or extEql(ext, "mkv")) return .video;
    if (extEql(ext, "bin") or extEql(ext, "dat")) return .binary;
    return .unknown;
}

pub fn inferMediaType(path: []const u8) ?[]const u8 {
    const ext = extension(path) orelse return null;
    if (extEql(ext, "png")) return "image/png";
    if (extEql(ext, "jpg") or extEql(ext, "jpeg")) return "image/jpeg";
    if (extEql(ext, "webp")) return "image/webp";
    if (extEql(ext, "gif")) return "image/gif";
    if (extEql(ext, "svg")) return "image/svg+xml";
    if (extEql(ext, "bmp")) return "image/bmp";
    if (extEql(ext, "ttf")) return "font/ttf";
    if (extEql(ext, "otf")) return "font/otf";
    if (extEql(ext, "woff")) return "font/woff";
    if (extEql(ext, "woff2")) return "font/woff2";
    if (extEql(ext, "txt")) return "text/plain";
    if (extEql(ext, "md")) return "text/markdown";
    if (extEql(ext, "csv")) return "text/csv";
    if (extEql(ext, "json")) return "application/json";
    if (extEql(ext, "strings")) return "text/plain";
    if (extEql(ext, "ftl")) return "text/plain";
    if (extEql(ext, "po")) return "text/plain";
    if (extEql(ext, "mo")) return "application/octet-stream";
    if (extEql(ext, "mp3")) return "audio/mpeg";
    if (extEql(ext, "wav")) return "audio/wav";
    if (extEql(ext, "ogg")) return "audio/ogg";
    if (extEql(ext, "flac")) return "audio/flac";
    if (extEql(ext, "m4a")) return "audio/mp4";
    if (extEql(ext, "mp4")) return "video/mp4";
    if (extEql(ext, "webm")) return "video/webm";
    if (extEql(ext, "mov")) return "video/quicktime";
    if (extEql(ext, "mkv")) return "video/x-matroska";
    if (extEql(ext, "bin") or extEql(ext, "dat")) return "application/octet-stream";
    return null;
}

fn validateNormalizedPath(path: []const u8) PathError!void {
    if (path.len == 0) return error.EmptyPath;
    if (isAbsolutePath(path)) return error.AbsolutePath;

    var segment_start: usize = 0;

    for (path, 0..) |ch, i| {
        if (ch == 0) return error.NullByte;
        if (ch == '\\') return error.AbsolutePath;
        if (ch == '/') {
            try validateSegmentForPath(path[segment_start..i]);
            segment_start = i + 1;
            continue;
        }
    }

    try validateSegmentForPath(path[segment_start..]);
}

fn validateSegmentForPath(segment: []const u8) PathError!void {
    if (segment.len == 0) return error.EmptySegment;
    if (std.mem.eql(u8, segment, ".")) return error.CurrentSegment;
    if (std.mem.eql(u8, segment, "..")) return error.ParentSegment;
}

fn validateIdSegment(segment: []const u8, segment_len: usize) IdError!void {
    if (segment_len == 0) return error.EmptySegment;
    if (std.mem.eql(u8, segment, ".")) return error.CurrentSegment;
    if (std.mem.eql(u8, segment, "..")) return error.ParentSegment;
}

fn isAbsolutePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return true;
    return path.len >= 3 and isAsciiAlpha(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
}

fn isIdChar(ch: u8) bool {
    return isAsciiAlpha(ch) or
        (ch >= '0' and ch <= '9') or
        ch == '_' or ch == '-' or ch == '.';
}

fn isAsciiAlpha(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

fn extension(path: []const u8) ?[]const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') return null;
        if (path[i] == '.') {
            if (i + 1 >= path.len) return null;
            return path[i + 1 ..];
        }
    }
    return null;
}

fn extEql(a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLowerAscii(ca) != cb) return false;
    }
    return true;
}

fn toLowerAscii(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + ('a' - 'A');
    return ch;
}

fn compareLex(a: []const u8, b: []const u8) i8 {
    const min_len = @min(a.len, b.len);
    for (a[0..min_len], b[0..min_len]) |ca, cb| {
        if (ca < cb) return -1;
        if (ca > cb) return 1;
    }
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

fn hexValue(ch: u8) HashError!u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => error.InvalidHashCharacter,
    };
}

fn hexByte(high: u8, low: u8) HashError!u8 {
    return (try hexValue(high)) << 4 | try hexValue(low);
}

fn writeHexByte(out: []u8, offset: usize, byte: u8) void {
    const chars = "0123456789abcdef";
    out[offset] = chars[byte >> 4];
    out[offset + 1] = chars[byte & 0x0f];
}

test "asset id validation accepts stable logical ids" {
    try validateId("icons/app");
    try validateId("fonts/inter/regular.ttf");
    try validateId("locales/en-US/messages");
    try std.testing.expectEqualStrings("icons/app", (try AssetId.init("icons/app")).value);
}

test "asset id validation rejects invalid forms" {
    try std.testing.expectError(error.EmptyId, validateId(""));
    try std.testing.expectError(error.AbsoluteId, validateId("/icons/app"));
    try std.testing.expectError(error.EmptySegment, validateId("icons//app"));
    try std.testing.expectError(error.CurrentSegment, validateId("icons/./app"));
    try std.testing.expectError(error.ParentSegment, validateId("icons/../app"));
    try std.testing.expectError(error.NullByte, validateId("icons\x00app"));
    try std.testing.expectError(error.InvalidCharacter, validateId("icons/app@2x"));
}

test "path normalization converts separators and rejects invalid paths" {
    var buffer: [64]u8 = undefined;

    try std.testing.expectEqualStrings("images/icons/app.png", try normalizePath(&buffer, "images\\icons/app.png"));
    try std.testing.expectError(error.EmptyPath, normalizePath(&buffer, ""));
    try std.testing.expectError(error.AbsolutePath, normalizePath(&buffer, "/assets/icon.png"));
    try std.testing.expectError(error.AbsolutePath, normalizePath(&buffer, "C:\\assets\\icon.png"));
    try std.testing.expectError(error.EmptySegment, normalizePath(&buffer, "assets//icon.png"));
    try std.testing.expectError(error.CurrentSegment, normalizePath(&buffer, "assets/./icon.png"));
    try std.testing.expectError(error.ParentSegment, normalizePath(&buffer, "assets/../icon.png"));
    try std.testing.expectError(error.NullByte, normalizePath(&buffer, "assets\x00icon.png"));
    try std.testing.expectError(error.NoSpaceLeft, normalizePath(buffer[0..4], "assets/icon.png"));
}

test "asset path validates normalized paths" {
    const path = try AssetPath.init("src/icon.png", "assets/icon.png");

    try std.testing.expectEqualStrings("src/icon.png", path.source);
    try std.testing.expectEqualStrings("assets/icon.png", path.bundle);
    try std.testing.expectError(error.AbsolutePath, AssetPath.init("/src/icon.png", "assets/icon.png"));
}

test "kind and media type inference covers common assets" {
    try std.testing.expectEqual(AssetKind.image, inferKind("icons/app.PNG"));
    try std.testing.expectEqual(AssetKind.font, inferKind("fonts/inter.woff2"));
    try std.testing.expectEqual(AssetKind.text, inferKind("copy/readme.md"));
    try std.testing.expectEqual(AssetKind.json, inferKind("data/app.json"));
    try std.testing.expectEqual(AssetKind.localization, inferKind("locales/en/messages.ftl"));
    try std.testing.expectEqual(AssetKind.audio, inferKind("sounds/click.wav"));
    try std.testing.expectEqual(AssetKind.video, inferKind("video/intro.webm"));
    try std.testing.expectEqual(AssetKind.binary, inferKind("data/blob.bin"));
    try std.testing.expectEqual(AssetKind.unknown, inferKind("data/blob.unknown"));

    try std.testing.expectEqualStrings("image/png", inferMediaType("icons/app.png").?);
    try std.testing.expectEqualStrings("font/woff2", inferMediaType("fonts/inter.woff2").?);
    try std.testing.expectEqualStrings("application/json", inferMediaType("data/app.json").?);
    try std.testing.expectEqualStrings("audio/wav", inferMediaType("sounds/click.wav").?);
    try std.testing.expectEqualStrings("video/webm", inferMediaType("video/intro.webm").?);
    try std.testing.expect(inferMediaType("data/blob.unknown") == null);
}

test "sha256 known vectors" {
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &hashHex(""),
    );
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &hashHex("abc"),
    );
}

test "hash hex parsing round trips and rejects invalid input" {
    const hash = sha256("abc");
    const hex = hash.toHex();

    try std.testing.expect(Hash.eql(hash, try parseHashHex(&hex)));
    try std.testing.expectError(error.InvalidHashLength, parseHashHex("abc"));
    try std.testing.expectError(error.InvalidHashCharacter, parseHashHex("zz7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
}

test "manifest lookup and validation" {
    const assets = [_]Asset{
        .{
            .id = "fonts/inter",
            .kind = .font,
            .source_path = "assets/fonts/inter.woff2",
            .bundle_path = "fonts/inter.woff2",
            .byte_len = 42,
            .hash = sha256("font"),
            .media_type = inferMediaType("inter.woff2"),
        },
        .{
            .id = "icons/app",
            .kind = .image,
            .source_path = "assets/icons/app.png",
            .bundle_path = "icons/app.png",
            .byte_len = 64,
            .hash = sha256("icon"),
            .media_type = inferMediaType("app.png"),
        },
    };
    const manifest: Manifest = .{ .assets = &assets };

    try manifest.validate();
    try std.testing.expectEqualStrings("icons/app", manifest.findById("icons/app").?.id);
    try std.testing.expectEqualStrings("fonts/inter", manifest.findByBundlePath("fonts/inter.woff2").?.id);
    try std.testing.expect(manifest.findById("missing") == null);
    try std.testing.expect(manifest.findByBundlePath("missing.png") == null);
}

test "manifest validation catches duplicates and unsorted entries" {
    const duplicate_ids = [_]Asset{
        .{ .id = "a", .source_path = "a.txt", .bundle_path = "a.txt" },
        .{ .id = "a", .source_path = "b.txt", .bundle_path = "b.txt" },
    };
    try std.testing.expectError(error.DuplicateId, (Manifest{ .assets = &duplicate_ids }).validate());

    const duplicate_bundle_paths = [_]Asset{
        .{ .id = "a", .source_path = "a.txt", .bundle_path = "same.txt" },
        .{ .id = "b", .source_path = "b.txt", .bundle_path = "same.txt" },
    };
    try std.testing.expectError(error.DuplicateBundlePath, (Manifest{ .assets = &duplicate_bundle_paths }).validate());

    const unsorted = [_]Asset{
        .{ .id = "b", .source_path = "b.txt", .bundle_path = "b.txt" },
        .{ .id = "a", .source_path = "a.txt", .bundle_path = "a.txt" },
    };
    try std.testing.expectError(error.UnsortedManifest, (Manifest{ .assets = &unsorted }).validate());

    const invalid_id = [_]Asset{
        .{ .id = "bad//id", .source_path = "a.txt", .bundle_path = "a.txt" },
    };
    try std.testing.expectError(error.InvalidId, (Manifest{ .assets = &invalid_id }).validate());

    const invalid_path = [_]Asset{
        .{ .id = "a", .source_path = "/a.txt", .bundle_path = "a.txt" },
    };
    try std.testing.expectError(error.InvalidPath, (Manifest{ .assets = &invalid_path }).validate());
}

test {
    std.testing.refAllDecls(@This());
}
