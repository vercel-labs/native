//! Decoder over the app-core Cmd/Sub wire format (rt.zig, cmd_format_version
//! 2), shared by the ts-track behavioral harnesses. The graders copy this
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
