//! Development view reload for compiled TypeScript views. A Debug app built
//! with `-Dview-reload` carries the development evaluator in its core; when
//! `native dev` launches it with `NATIVE_SDK_DEV_VIEW=<dir>`, the app
//! announces its session and contract in `<dir>/build.json`, and the markup
//! watcher answers each edit with `<dir>/view.update`:
//!
//!   magic "NSDV", u32 format, u64 session, u8 kind, sha256(body), u32 length, body
//!
//! (packages/core/src/view_reload.ts writes it). An update for another
//! session, with a bad digest, or of an unknown format is never applied. A
//! program the core refuses and a markup diagnostic both keep the last good
//! view; the app reports them through its markup diagnostic. The model is
//! never touched: a reload is an ordinary rebuild of every open window.
const std = @import("std");
const canvas = @import("canvas");

pub const Outcome = enum { unchanged, reloaded, failed };

/// The app's side of the loop: `poll` runs on the markup watch timer.
/// `.failed` fills `diagnostic` with bytes that stay valid until the next
/// poll.
pub const Hook = struct {
    context: *anyopaque,
    poll: *const fn (context: *anyopaque, diagnostic: *canvas.ui_markup.MarkupErrorInfo) Outcome,
};

/// The hook a Debug app's markup watch timer polls. The app wiring installs
/// it at launch when `native dev` arms reload (one reloading app per
/// process). Only Debug code reads it, so release builds carry nothing.
pub var installed: ?Hook = null;

/// The markup files the last decoded main view names (a reloading
/// compiled view under automation): stamped path, path on disk relative
/// to the app's working directory, and the Wyhash of the bytes the view
/// was compiled from. The strings borrow the build's arena; the app copies
/// them into its provenance table before the arena resets.
pub const ViewFile = struct { stamped: []const u8, disk: []const u8, hash: u64 };
pub const max_view_files = 32;
pub var view_files: [max_view_files]ViewFile = undefined;
pub var view_files_len: usize = 0;

pub const env_var = "NATIVE_SDK_DEV_VIEW";
pub const build_file = "build.json";
pub const update_file = "view.update";
pub const format: u32 = 1;
pub const header_len = 53;
/// Programs are bounded by the markup limits; this only caps a damaged file.
pub const max_update_bytes = 64 * 1024 * 1024;

pub const Kind = enum(u8) { program = 0, diagnostic = 1, compiled = 2 };

pub const Header = struct {
    session: u64,
    kind: Kind,
    digest: [32]u8,
    len: u32,
};

/// The header of an update, or null when it is not one this build reads.
pub fn decodeHeader(bytes: []const u8) ?Header {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..4], "NSDV")) return null;
    if (std.mem.readInt(u32, bytes[4..8], .little) != format) return null;
    const kind = std.enums.fromInt(Kind, bytes[16]) orelse return null;
    return .{
        .session = std.mem.readInt(u64, bytes[8..16], .little),
        .kind = kind,
        .digest = bytes[17..49].*,
        .len = std.mem.readInt(u32, bytes[49..53], .little),
    };
}

/// The body of a complete update whose digest matches, else null.
pub fn verifiedBody(header: Header, bytes: []const u8) ?[]const u8 {
    if (bytes.len != header_len + @as(usize, header.len)) return null;
    const body = bytes[header_len..];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    if (!std.mem.eql(u8, &digest, &header.digest)) return null;
    return body;
}

/// u32 line, u32 column, u32 path length, path, u32 message length, message.
pub fn decodeDiagnostic(body: []const u8) ?canvas.ui_markup.MarkupErrorInfo {
    if (body.len < 12) return null;
    const path_len = std.mem.readInt(u32, body[8..12], .little);
    if (body.len < 16 + @as(usize, path_len)) return null;
    const message_at = 16 + @as(usize, path_len);
    const message_len = std.mem.readInt(u32, body[12 + path_len ..][0..4], .little);
    if (body.len != message_at + @as(usize, message_len)) return null;
    return .{
        .line = std.mem.readInt(u32, body[0..4], .little),
        .column = std.mem.readInt(u32, body[4..8], .little),
        .path = body[12..][0..path_len],
        .message = body[message_at..],
    };
}

/// The reload driver for one compiled core. `core` is the generated mirror
/// of a view-reload build (it declares `nativeDevViewPrepare`).
pub fn Driver(comptime core: type) type {
    return struct {
        const Self = @This();

        io: std.Io,
        dir: std.Io.Dir,
        session: u64,
        arena: std.heap.ArenaAllocator,
        /// Digest of the last update acted on; a repeated poll of the same
        /// file does nothing.
        applied: ?[32]u8 = null,

        /// Open `dir_path` (created if needed) for a fresh session.
        pub fn init(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, session: u64) !Self {
            const dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
            return .{ .io = io, .dir = dir, .session = session, .arena = .init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.dir.close(self.io);
            self.arena.deinit();
        }

        /// Tell the watcher which session and contract to compile for. Any
        /// update from an earlier session is discarded first.
        pub fn announce(self: *Self, contract: []const u8) !void {
            self.dir.deleteFile(self.io, update_file) catch {};
            var text: std.Io.Writer.Allocating = .init(self.arena.allocator());
            defer _ = self.arena.reset(.retain_capacity);
            try text.writer.print("{{\"format\":{d},\"session\":\"{x:0>16}\",\"contract\":", .{ format, self.session });
            try text.writer.writeAll(std.mem.trim(u8, contract, " \r\n"));
            try text.writer.writeAll("}\n");
            var atomic = try self.dir.createFileAtomic(self.io, build_file, .{ .replace = true });
            defer atomic.deinit(self.io);
            try atomic.file.writePositionalAll(self.io, text.written(), 0);
            try atomic.replace(self.io);
        }

        pub fn hook(self: *Self) Hook {
            return .{ .context = self, .poll = pollOpaque };
        }

        fn pollOpaque(context: *anyopaque, diagnostic: *canvas.ui_markup.MarkupErrorInfo) Outcome {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.poll(diagnostic);
        }

        pub fn poll(self: *Self, diagnostic: *canvas.ui_markup.MarkupErrorInfo) Outcome {
            _ = self.arena.reset(.retain_capacity);
            const arena = self.arena.allocator();
            const file = self.dir.openFile(self.io, update_file, .{}) catch return .unchanged;
            defer file.close(self.io);
            var head: [header_len]u8 = undefined;
            const head_len = file.readPositionalAll(self.io, &head, 0) catch return .unchanged;
            const header = decodeHeader(head[0..head_len]) orelse return .unchanged;
            if (header.session != self.session) return .unchanged;
            if (self.applied) |digest| if (std.mem.eql(u8, &digest, &header.digest)) return .unchanged;
            const total = header_len + @as(usize, header.len);
            if (total > max_update_bytes) return .unchanged;
            const bytes = arena.alloc(u8, total) catch return .unchanged;
            const read = file.readPositionalAll(self.io, bytes, 0) catch return .unchanged;
            // A file still being replaced reads short or fails its digest;
            // it is retried on the next poll, never applied.
            const body = verifiedBody(header, bytes[0..read]) orelse return .unchanged;
            self.applied = header.digest;
            switch (header.kind) {
                .program => {
                    const refused = core.nativeDevViewPrepare(body, arena);
                    if (refused.len == 0) return .reloaded;
                    diagnostic.* = .{ .message = refused };
                    return .failed;
                },
                .diagnostic => {
                    diagnostic.* = decodeDiagnostic(body) orelse .{ .message = "the markup watcher sent an unreadable diagnostic; restart native dev" };
                    return .failed;
                },
                .compiled => {
                    core.nativeDevViewReset();
                    return .reloaded;
                },
            }
        }
    };
}

test "an update is read only when complete, current and for this session" {
    const body = "program bytes";
    var bytes: [header_len + body.len]u8 = undefined;
    @memcpy(bytes[0..4], "NSDV");
    std.mem.writeInt(u32, bytes[4..8], format, .little);
    std.mem.writeInt(u64, bytes[8..16], 0x0123456789abcdef, .little);
    bytes[16] = 0;
    std.crypto.hash.sha2.Sha256.hash(body, bytes[17..49], .{});
    std.mem.writeInt(u32, bytes[49..53], body.len, .little);
    @memcpy(bytes[header_len..], body);
    const header = decodeHeader(&bytes).?;
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), header.session);
    try std.testing.expectEqual(Kind.program, header.kind);
    try std.testing.expectEqualStrings(body, verifiedBody(header, &bytes).?);
    try std.testing.expect(verifiedBody(header, bytes[0 .. bytes.len - 1]) == null);
    var damaged = bytes;
    damaged[header_len] ^= 1;
    try std.testing.expect(verifiedBody(header, &damaged) == null);
    var future = bytes;
    std.mem.writeInt(u32, future[4..8], format + 1, .little);
    try std.testing.expect(decodeHeader(&future) == null);
    future = bytes;
    future[16] = 3;
    try std.testing.expect(decodeHeader(&future) == null);
    try std.testing.expect(decodeHeader(bytes[0 .. header_len - 1]) == null);
}

test "a diagnostic carries its location" {
    var body: [16 + 14 + 5]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], 3, .little);
    std.mem.writeInt(u32, body[4..8], 7, .little);
    std.mem.writeInt(u32, body[8..12], 14, .little);
    @memcpy(body[12..26], "src/app.native");
    std.mem.writeInt(u32, body[26..30], 5, .little);
    @memcpy(body[30..], "oops!");
    const info = decodeDiagnostic(&body).?;
    try std.testing.expectEqual(@as(usize, 3), info.line);
    try std.testing.expectEqual(@as(usize, 7), info.column);
    try std.testing.expectEqualStrings("src/app.native", info.path);
    try std.testing.expectEqualStrings("oops!", info.message);
    try std.testing.expect(decodeDiagnostic(body[0 .. body.len - 1]) == null);
}
