//! Decoder over the app-core Cmd/Sub wire format (rt.zig, cmd_format_version
//! 3), shared by the ts-track behavioral harnesses. The graders copy this
//! file next to each case's harness so assertions read decoded ops — "a
//! fetch with key `feed` targeting this URL", "the delay re-armed" — instead
//! of hand-built byte strings, which keeps harnesses lenient about the parts
//! a case does not pin (timeouts, header order, batching).
//!
//! A Cmd value is a flat concatenation of op records; iterate them with
//! `CmdIter`. Sub values share the encoding (`SubIter`).

const std = @import("std");

pub const Op = union(enum) {
    persist,
    now: struct { msg_tag: u8 },
    host: Host,
    host_bytes: struct { name: []const u8, payload: []const u8 },
    request: struct { name: []const u8, key: []const u8, ok_tag: u8, err_tag: u8, payload: []const u8 },
    cancel: struct { key: []const u8 },
    read_file: struct { key: []const u8, ok_tag: u8, err_tag: u8, path: []const u8 },
    write_file: struct { key: []const u8, ok_tag: u8, err_tag: u8, path: []const u8, bytes: []const u8 },
    fetch: Fetch,
    clip_write: struct { bytes: []const u8 },
    clip_read: struct { key: []const u8, ok_tag: u8, err_tag: u8 },
    delay: struct { key: []const u8, after_ms: f64, msg_tag: u8 },
    spawn: Spawn,
    audio_play: struct { key: []const u8, event_tag: u8, path: []const u8, url: []const u8, cache_path: []const u8, expected_bytes: f64 },
    audio_ctl: struct { key: []const u8, verb: u8, value: f64 },
    window_show: struct { label: []const u8 },
    quit_app,
    image_load: struct { id: f64, event_tag: u8, path: []const u8, url: []const u8, cache_path: []const u8, expected_bytes: f64 },
    image_cancel: struct { id: f64 },
    image_unregister: struct { id: f64 },

    pub const Host = struct {
        name: []const u8,
        /// f64 args, little-endian, 8 bytes each.
        arg_bytes: []const u8,

        pub fn argCount(self: Host) usize {
            return self.arg_bytes.len / 8;
        }

        pub fn arg(self: Host, index: usize) f64 {
            return @bitCast(std.mem.readInt(u64, self.arg_bytes[index * 8 ..][0..8], .little));
        }
    };

    pub const Fetch = struct {
        key: []const u8,
        ok_tag: u8,
        err_tag: u8,
        /// rt.CmdFetchMethod declaration order: GET 0, POST 1, PUT 2,
        /// DELETE 3, PATCH 4, HEAD 5.
        method: u8,
        timeout_ms: u32,
        url: []const u8,
        header_count: u8,
        /// Raw header block: per header [name_len u8][name][value_len u32 LE][value].
        header_bytes: []const u8,
        body: []const u8,
    };

    pub const Spawn = struct {
        key: []const u8,
        /// 0xFF = no line routing (rt.spawn_no_line_tag).
        line_tag: u8,
        exit_tag: u8,
        err_tag: u8,
        /// rt.CmdSpawnMode: lines 0, collect 1.
        mode: u8,
        arg_count: u8,
        /// Raw argv block: per element [len u32 LE][bytes].
        argv_bytes: []const u8,
        stdin: []const u8,

        pub fn arg(self: Spawn, index: usize) []const u8 {
            var off: usize = 0;
            var i: usize = 0;
            while (true) {
                const len = std.mem.readInt(u32, self.argv_bytes[off..][0..4], .little);
                if (i == index) return self.argv_bytes[off + 4 ..][0..len];
                off += 4 + len;
                i += 1;
            }
        }
    };
};

pub const CmdIter = struct {
    bytes: []const u8,
    off: usize = 0,

    pub fn init(bytes: []const u8) CmdIter {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *CmdIter) ?Op {
        if (self.off >= self.bytes.len) return null;
        const b = self.bytes;
        var off = self.off;
        const op = b[off];
        off += 1;
        const decoded: Op = switch (op) {
            0x01 => .persist,
            0x02 => blk: {
                const tag = b[off];
                off += 1;
                break :blk .{ .now = .{ .msg_tag = tag } };
            },
            0x03 => blk: {
                const name = shortBytes(b, &off);
                const argc = b[off];
                off += 1;
                const args = b[off..][0 .. @as(usize, argc) * 8];
                off += args.len;
                break :blk .{ .host = .{ .name = name, .arg_bytes = args } };
            },
            0x04 => blk: {
                const name = shortBytes(b, &off);
                const payload = longBytes(b, &off);
                break :blk .{ .host_bytes = .{ .name = name, .payload = payload } };
            },
            0x05 => blk: {
                const name = shortBytes(b, &off);
                const key = shortBytes(b, &off);
                const ok = b[off];
                const err = b[off + 1];
                off += 2;
                const payload = longBytes(b, &off);
                break :blk .{ .request = .{ .name = name, .key = key, .ok_tag = ok, .err_tag = err, .payload = payload } };
            },
            0x06 => blk: {
                const key = shortBytes(b, &off);
                break :blk .{ .cancel = .{ .key = key } };
            },
            0x07 => blk: {
                const head = routedHead(b, &off);
                const path = longBytes(b, &off);
                break :blk .{ .read_file = .{ .key = head.key, .ok_tag = head.ok, .err_tag = head.err, .path = path } };
            },
            0x08 => blk: {
                const head = routedHead(b, &off);
                const path = longBytes(b, &off);
                const bytes = longBytes(b, &off);
                break :blk .{ .write_file = .{ .key = head.key, .ok_tag = head.ok, .err_tag = head.err, .path = path, .bytes = bytes } };
            },
            0x09 => blk: {
                const head = routedHead(b, &off);
                const method = b[off];
                off += 1;
                const timeout = std.mem.readInt(u32, b[off..][0..4], .little);
                off += 4;
                const url = longBytes(b, &off);
                const header_count = b[off];
                off += 1;
                const headers_start = off;
                var h: usize = 0;
                while (h < header_count) : (h += 1) {
                    _ = shortBytes(b, &off);
                    _ = longBytes(b, &off);
                }
                const header_bytes = b[headers_start..off];
                const body = longBytes(b, &off);
                break :blk .{ .fetch = .{ .key = head.key, .ok_tag = head.ok, .err_tag = head.err, .method = method, .timeout_ms = timeout, .url = url, .header_count = header_count, .header_bytes = header_bytes, .body = body } };
            },
            0x0A => blk: {
                const bytes = longBytes(b, &off);
                break :blk .{ .clip_write = .{ .bytes = bytes } };
            },
            0x0B => blk: {
                const head = routedHead(b, &off);
                break :blk .{ .clip_read = .{ .key = head.key, .ok_tag = head.ok, .err_tag = head.err } };
            },
            0x0C => blk: {
                const key = shortBytes(b, &off);
                const after: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                const tag = b[off];
                off += 1;
                break :blk .{ .delay = .{ .key = key, .after_ms = after, .msg_tag = tag } };
            },
            0x0D => blk: {
                const key = shortBytes(b, &off);
                const line_tag = b[off];
                const exit_tag = b[off + 1];
                const err_tag = b[off + 2];
                const mode = b[off + 3];
                const argc = b[off + 4];
                off += 5;
                const argv_start = off;
                var i: usize = 0;
                while (i < argc) : (i += 1) _ = longBytes(b, &off);
                const argv_bytes = b[argv_start..off];
                const stdin = longBytes(b, &off);
                break :blk .{ .spawn = .{ .key = key, .line_tag = line_tag, .exit_tag = exit_tag, .err_tag = err_tag, .mode = mode, .arg_count = argc, .argv_bytes = argv_bytes, .stdin = stdin } };
            },
            0x0E => blk: {
                const key = shortBytes(b, &off);
                const event_tag = b[off];
                off += 1;
                const path = longBytes(b, &off);
                const url = longBytes(b, &off);
                const cache = longBytes(b, &off);
                const expected: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                break :blk .{ .audio_play = .{ .key = key, .event_tag = event_tag, .path = path, .url = url, .cache_path = cache, .expected_bytes = expected } };
            },
            0x0F => blk: {
                const key = shortBytes(b, &off);
                const verb = b[off];
                off += 1;
                const value: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                break :blk .{ .audio_ctl = .{ .key = key, .verb = verb, .value = value } };
            },
            // window_show [op][label_len u8][label] — the record shape the
            // runtime's decoder reads (src/runtime/ts_core_host.zig, 0x10:
            // one short-bytes label, nothing else).
            0x10 => blk: {
                const label = shortBytes(b, &off);
                break :blk .{ .window_show = .{ .label = label } };
            },
            // quit_app [op] — a bare op byte, no payload (ts_core_host.zig,
            // 0x11).
            0x11 => .quit_app,
            // image_load [op][id f64 LE][event_tag u8][path_len u32 LE][path]
            // [url_len u32 LE][url][cache_len u32 LE][cache][expected f64 LE]
            // — audio_play's source-cascade record shape keyed by the numeric
            // ImageId instead of a string key (ts_core_host.zig, 0x12).
            0x12 => blk: {
                const id: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                const event_tag = b[off];
                off += 1;
                const path = longBytes(b, &off);
                const url = longBytes(b, &off);
                const cache = longBytes(b, &off);
                const expected: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                break :blk .{ .image_load = .{ .id = id, .event_tag = event_tag, .path = path, .url = url, .cache_path = cache, .expected_bytes = expected } };
            },
            // image_cancel [op][id f64 LE] (ts_core_host.zig, 0x13).
            0x13 => blk: {
                const id: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                break :blk .{ .image_cancel = .{ .id = id } };
            },
            // image_unregister [op][id f64 LE] (ts_core_host.zig, 0x14).
            0x14 => blk: {
                const id: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                break :blk .{ .image_unregister = .{ .id = id } };
            },
            else => std.debug.panic("cmdview: unknown op byte 0x{X:0>2} at offset {d}", .{ op, self.off }),
        };
        self.off = off;
        return decoded;
    }
};

/// Sub records share the framing; today's only op is the repeating timer.
pub const SubOp = union(enum) {
    timer: struct { key: []const u8, every_ms: f64, msg_tag: u8 },
};

pub const SubIter = struct {
    bytes: []const u8,
    off: usize = 0,

    pub fn init(bytes: []const u8) SubIter {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *SubIter) ?SubOp {
        if (self.off >= self.bytes.len) return null;
        const b = self.bytes;
        var off = self.off;
        const op = b[off];
        off += 1;
        if (op != 0x01) std.debug.panic("cmdview: unknown sub op byte 0x{X:0>2}", .{op});
        const key = shortBytes(b, &off);
        const every: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
        off += 8;
        const tag = b[off];
        off += 1;
        self.off = off;
        return .{ .timer = .{ .key = key, .every_ms = every, .msg_tag = tag } };
    }
};

const RoutedHead = struct { key: []const u8, ok: u8, err: u8 };

fn routedHead(b: []const u8, off: *usize) RoutedHead {
    const key = shortBytes(b, off);
    const ok = b[off.*];
    const err = b[off.* + 1];
    off.* += 2;
    return .{ .key = key, .ok = ok, .err = err };
}

fn shortBytes(b: []const u8, off: *usize) []const u8 {
    const len = b[off.*];
    const out = b[off.* + 1 ..][0..len];
    off.* += 1 + len;
    return out;
}

fn longBytes(b: []const u8, off: *usize) []const u8 {
    const len = std.mem.readInt(u32, b[off.*..][0..4], .little);
    const out = b[off.* + 4 ..][0..len];
    off.* += 4 + len;
    return out;
}

// ------------------------------------------------------------------ helpers

/// First decoded op of the given kind in a cmd buffer, or null.
pub fn findOp(bytes: []const u8, comptime kind: std.meta.Tag(Op)) ?@FieldType(Op, @tagName(kind)) {
    var iter = CmdIter.init(bytes);
    while (iter.next()) |op| {
        if (op == kind) return @field(op, @tagName(kind));
    }
    return null;
}

/// Count of decoded ops of the given kind in a cmd buffer.
pub fn countOps(bytes: []const u8, comptime kind: std.meta.Tag(Op)) usize {
    var iter = CmdIter.init(bytes);
    var n: usize = 0;
    while (iter.next()) |op| {
        if (op == kind) n += 1;
    }
    return n;
}

/// First timer descriptor in a Sub buffer, or null.
pub fn findTimer(bytes: []const u8) ?@FieldType(SubOp, "timer") {
    var iter = SubIter.init(bytes);
    while (iter.next()) |op| {
        return op.timer;
    }
    return null;
}

// ------------------------------------------------------------------- tests
//
// The wire bytes below are the encoders' pinned output (rt.zig
// cmdWindowShow/cmdQuitApp — the same bytes packages/core/test/effects.test.ts
// asserts), so a decoder drift from the format is caught here instead of
// panicking mid-eval inside a case harness.

test "window_show and quit_app decode, alone and inside a batch" {
    // window_show: [op 0x10][label_len u8][label bytes].
    const shown = findOp(&.{ 0x10, 6, 'p', 'l', 'a', 'y', 'e', 'r' }, .window_show) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("player", shown.label);

    // quit_app: [op 0x11], no payload.
    try std.testing.expectEqual(@as(usize, 1), countOps(&.{0x11}, .quit_app));

    // A batch is a flat concatenation: both records must advance the
    // iterator exactly their own length, so the trailing now record
    // still decodes (a length drift would misread its op byte).
    const batch = [_]u8{ 0x10, 4, 'm', 'a', 'i', 'n', 0x11, 0x02, 7 };
    var iter = CmdIter.init(&batch);
    const first = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("main", first.window_show.label);
    const second = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expect(second == .quit_app);
    const third = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 7), third.now.msg_tag);
    try std.testing.expectEqual(@as(?Op, null), iter.next());
}

test "the image records decode, alone and inside a batch" {
    // image_load: [op 0x12][id f64 LE][event_tag][path][url][cache]
    // [expected f64 LE] — the bytes rt.zig's cmdImageLoad pins (the same
    // layout packages/core/test/effects.test.ts asserts).
    var load_bytes: std.ArrayList(u8) = .empty;
    defer load_bytes.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try load_bytes.append(a, 0x12);
    try load_bytes.appendSlice(a, &@as([8]u8, @bitCast(@as(f64, 7))));
    try load_bytes.append(a, 3); // event_tag
    try load_bytes.appendSlice(a, &.{ 13, 0, 0, 0 });
    try load_bytes.appendSlice(a, "art/cover.png");
    try load_bytes.appendSlice(a, &.{ 0, 0, 0, 0 }); // url: empty
    try load_bytes.appendSlice(a, &.{ 0, 0, 0, 0 }); // cache: empty
    try load_bytes.appendSlice(a, &@as([8]u8, @bitCast(@as(f64, 2048))));
    const load = findOp(load_bytes.items, .image_load) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 7), load.id);
    try std.testing.expectEqual(@as(u8, 3), load.event_tag);
    try std.testing.expectEqualStrings("art/cover.png", load.path);
    try std.testing.expectEqualStrings("", load.url);
    try std.testing.expectEqual(@as(f64, 2048), load.expected_bytes);

    // image_cancel [op 0x13][id f64 LE] and image_unregister
    // [op 0x14][id f64 LE] concatenated: both one-field records must
    // advance exactly nine bytes each for the second to decode.
    var batch: [18]u8 = undefined;
    batch[0] = 0x13;
    batch[1..9].* = @bitCast(@as(f64, 7));
    batch[9] = 0x14;
    batch[10..18].* = @bitCast(@as(f64, 15));
    var iter = CmdIter.init(&batch);
    const cancelled = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 7), cancelled.image_cancel.id);
    const evicted = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 15), evicted.image_unregister.id);
    try std.testing.expectEqual(@as(?Op, null), iter.next());
}
