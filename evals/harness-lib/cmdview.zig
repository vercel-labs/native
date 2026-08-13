//! Decoder over the app-core Cmd/Sub wire format (rt.zig, cmd_format_version
//! 6), shared by the ts-track behavioral harnesses. The graders copy this
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
    request: struct { name: []const u8, key: []const u8, ok_tag: u8, err_tag: u8, typed_service: bool, payload: []const u8 },
    service_stream_request: struct {
        channel_key: f64,
        event_tag: u8,
        max_pending: u8,
        name: []const u8,
        key: []const u8,
        ok_tag: u8,
        err_tag: u8,
        payload: []const u8,
    },
    cancel: struct { key: []const u8 },
    read_file: struct { key: []const u8, ok_tag: u8, err_tag: u8, path: []const u8 },
    write_file: struct { key: []const u8, ok_tag: u8, err_tag: u8, path: []const u8, bytes: []const u8 },
    append_file: struct { key: []const u8, ok_tag: u8, err_tag: u8, path: []const u8, bytes: []const u8 },
    stat_file: struct { key: []const u8, ok_tag: u8, err_tag: u8, path: []const u8 },
    read_file_stream: struct { key: []const u8, chunk_tag: u8, done_tag: u8, err_tag: u8, path: []const u8 },
    write_file_stream: struct { key: []const u8, ok_tag: u8, err_tag: u8, path: []const u8 },
    write_file_chunk: struct { key: []const u8, ok_tag: u8, err_tag: u8, bytes: []const u8 },
    write_file_close: struct { key: []const u8, ok_tag: u8, err_tag: u8 },
    fetch: Fetch,
    fetch_stream: FetchStream,
    clip_write: struct { bytes: []const u8 },
    clip_read: struct { key: []const u8, ok_tag: u8, err_tag: u8 },
    delay: struct { key: []const u8, after_ms: f64, msg_tag: u8 },
    spawn: Spawn,
    audio_play: struct { key: []const u8, event_tag: u8, path: []const u8, url: []const u8, cache_path: []const u8, expected_bytes: f64 },
    audio_ctl: struct { key: []const u8, verb: u8, value: f64 },
    window_show: struct { label: []const u8 },
    window_hide: struct { label: []const u8 },
    dock_presence: struct { visible: bool },
    store_set: struct { key: []const u8, ok_tag: u8, err_tag: u8, scope: u32, store_key: []const u8, bytes: []const u8 },
    store_get: struct { key: []const u8, ok_tag: u8, err_tag: u8, scope: u32, store_key: []const u8 },
    store_delete: struct { key: []const u8, ok_tag: u8, err_tag: u8, scope: u32, store_key: []const u8 },
    store_scan: struct { key: []const u8, ok_tag: u8, err_tag: u8, scope: u32, prefix: []const u8, limit: u32, after: []const u8 },
    store_set_many: StoreSetMany,
    quit_app,
    image_load: struct { id: f64, event_tag: u8, path: []const u8, url: []const u8, cache_path: []const u8, expected_bytes: f64 },
    image_cancel: struct { id: f64 },
    image_unregister: struct { id: f64 },
    channel_open: struct { key: f64, event_tag: u8, max_pending: u8 },
    channel_close: struct { key: f64 },
    pty_spawn: PtySpawn,
    pty_write: struct { key: []const u8, bytes: []const u8 },
    pty_resize: struct { key: []const u8, cols: f64, rows: f64 },
    pty_kill: struct { key: []const u8 },
    show_notification: struct { id: []const u8, title: []const u8, subtitle: []const u8, body: []const u8, action_label: []const u8, action_command: []const u8 },
    audio_capture_start: struct { key: f64, source: u8, sample_rate: u32, channels: u8, event_tag: u8 },
    audio_capture_stop: struct { key: f64 },

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

    pub const FetchStream = struct {
        key: []const u8,
        line_tag: u8,
        ok_tag: u8,
        err_tag: u8,
        method: u8,
        timeout_ms: u32,
        max_line_bytes: u32,
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

    pub const PtySpawn = struct {
        key: []const u8,
        event_tag: u8,
        /// f64 subset numbers on the wire; the host's transport is u16.
        cols: f64,
        rows: f64,
        /// "" = the engine's default TERM.
        term: []const u8,
        arg_count: u8,
        /// Raw argv block: per element [len u32 LE][bytes] (the spawn
        /// record's encoding).
        argv_bytes: []const u8,

        pub fn arg(self: PtySpawn, index: usize) []const u8 {
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

    pub const StoreSetMany = struct {
        key: []const u8,
        ok_tag: u8,
        err_tag: u8,
        scope: u32,
        count: u32,
        /// Raw entries: `[key_len u32][key][value_len u32][value]`.
        entry_bytes: []const u8,

        pub fn entry(self: StoreSetMany, index: usize) struct { key: []const u8, bytes: []const u8 } {
            var off: usize = 0;
            var i: usize = 0;
            while (true) : (i += 1) {
                const key = longBytes(self.entry_bytes, &off);
                const bytes = longBytes(self.entry_bytes, &off);
                if (i == index) return .{ .key = key, .bytes = bytes };
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
                const typed_service = b[off + 2] != 0;
                off += 3;
                const payload = longBytes(b, &off);
                break :blk .{ .request = .{ .name = name, .key = key, .ok_tag = ok, .err_tag = err, .typed_service = typed_service, .payload = payload } };
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
            // channel_open [op][key f64 LE][event_tag u8][max_pending u8] — the bytes
            // rt.zig's cmdChannelOpen builds (ts_core_host.zig, 0x15).
            0x15 => blk: {
                const key: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                const event_tag = b[off];
                const max_pending = b[off + 1];
                off += 2;
                break :blk .{ .channel_open = .{ .key = key, .event_tag = event_tag, .max_pending = max_pending } };
            },
            // channel_close [op][key f64 LE] (ts_core_host.zig, 0x16).
            0x16 => blk: {
                const key: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                break :blk .{ .channel_close = .{ .key = key } };
            },
            // pty_spawn [op 0x19][key_len u8][key][event_tag u8]
            // [cols f64 LE][rows f64 LE][term_len u8][term][argc u8]
            // ([arg_len u32 LE][arg])* — the spawn record's argv encoding
            // with the pty grid and TERM aboard (ts_core_host.zig, 0x19;
            // 0x17-0x18 are reserved).
            0x19 => blk: {
                const key = shortBytes(b, &off);
                const event_tag = b[off];
                off += 1;
                const cols: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                const rows: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                const term = shortBytes(b, &off);
                const argc = b[off];
                off += 1;
                const argv_start = off;
                var i: usize = 0;
                while (i < argc) : (i += 1) _ = longBytes(b, &off);
                const argv_bytes = b[argv_start..off];
                break :blk .{ .pty_spawn = .{ .key = key, .event_tag = event_tag, .cols = cols, .rows = rows, .term = term, .arg_count = argc, .argv_bytes = argv_bytes } };
            },
            // pty_write [op 0x1A][key_len u8][key][bytes_len u32 LE][bytes]
            // (ts_core_host.zig, 0x1A).
            0x1A => blk: {
                const key = shortBytes(b, &off);
                const bytes = longBytes(b, &off);
                break :blk .{ .pty_write = .{ .key = key, .bytes = bytes } };
            },
            // pty_resize [op 0x1B][key_len u8][key][cols f64 LE][rows f64 LE]
            // (ts_core_host.zig, 0x1B).
            0x1B => blk: {
                const key = shortBytes(b, &off);
                const cols: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                const rows: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                break :blk .{ .pty_resize = .{ .key = key, .cols = cols, .rows = rows } };
            },
            // pty_kill [op 0x1C][key_len u8][key] (ts_core_host.zig, 0x1C).
            0x1C => blk: {
                const key = shortBytes(b, &off);
                break :blk .{ .pty_kill = .{ .key = key } };
            },
            // show_notification [op 0x1D][title/subtitle/body as u32-length
            // bytes] (ts_core_host.zig, 0x1D).
            0x1D => blk: {
                const title = longBytes(b, &off);
                const subtitle = longBytes(b, &off);
                const body = longBytes(b, &off);
                break :blk .{ .show_notification = .{ .id = "", .title = title, .subtitle = subtitle, .body = body, .action_label = "", .action_command = "" } };
            },
            // audio_capture_start [op 0x1E][key f64 LE][source u8]
            // [sample_rate u32 LE][channels u8][event_tag u8].
            0x1E => blk: {
                const key: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                const source = b[off];
                off += 1;
                const sample_rate = std.mem.readInt(u32, b[off..][0..4], .little);
                off += 4;
                const channels = b[off];
                const event_tag = b[off + 1];
                off += 2;
                break :blk .{ .audio_capture_start = .{
                    .key = key,
                    .source = source,
                    .sample_rate = sample_rate,
                    .channels = channels,
                    .event_tag = event_tag,
                } };
            },
            // audio_capture_stop [op 0x1F][key f64 LE].
            0x1F => blk: {
                const key: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                break :blk .{ .audio_capture_stop = .{ .key = key } };
            },
            // fetch_stream [op 0x20][key][line/ok/err tags][method]
            // [timeout u32 LE][max line u32 LE][url][headers][body]
            // (ts_core_host.zig, 0x20).
            0x20 => blk: {
                const key = shortBytes(b, &off);
                const line_tag = b[off];
                const ok_tag = b[off + 1];
                const err_tag = b[off + 2];
                const method = b[off + 3];
                off += 4;
                const timeout = std.mem.readInt(u32, b[off..][0..4], .little);
                off += 4;
                const max_line_bytes = std.mem.readInt(u32, b[off..][0..4], .little);
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
                break :blk .{ .fetch_stream = .{
                    .key = key,
                    .line_tag = line_tag,
                    .ok_tag = ok_tag,
                    .err_tag = err_tag,
                    .method = method,
                    .timeout_ms = timeout,
                    .max_line_bytes = max_line_bytes,
                    .url = url,
                    .header_count = header_count,
                    .header_bytes = header_bytes,
                    .body = body,
                } };
            },
            // actionable_notification [op 0x31][id/title/subtitle/body/
            // action_label/action_command as u32-length bytes].
            0x31 => blk: {
                const id = longBytes(b, &off);
                const title = longBytes(b, &off);
                const subtitle = longBytes(b, &off);
                const body = longBytes(b, &off);
                const action_label = longBytes(b, &off);
                const action_command = longBytes(b, &off);
                break :blk .{ .show_notification = .{
                    .id = id,
                    .title = title,
                    .subtitle = subtitle,
                    .body = body,
                    .action_label = action_label,
                    .action_command = action_command,
                } };
            },
            // window_hide [op 0x21][label_len u8][label].
            0x21 => blk: {
                const label = shortBytes(b, &off);
                break :blk .{ .window_hide = .{ .label = label } };
            },
            // dock_presence [op 0x22][visible u8].
            0x22 => blk: {
                const visible = b[off] != 0;
                off += 1;
                break :blk .{ .dock_presence = .{ .visible = visible } };
            },
            // Atomic typed streaming-service admission.
            0x28 => blk: {
                const channel_key: f64 = @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
                off += 8;
                const event_tag = b[off];
                const max_pending = b[off + 1];
                off += 2;
                const name = shortBytes(b, &off);
                const key = shortBytes(b, &off);
                const ok_tag = b[off];
                const err_tag = b[off + 1];
                off += 2;
                const payload = longBytes(b, &off);
                break :blk .{ .service_stream_request = .{
                    .channel_key = channel_key,
                    .event_tag = event_tag,
                    .max_pending = max_pending,
                    .name = name,
                    .key = key,
                    .ok_tag = ok_tag,
                    .err_tag = err_tag,
                    .payload = payload,
                } };
            },
            0x23 => blk: {
                const head = routedHead(b, &off);
                const scope = readU32(b, &off);
                const store_key = longBytes(b, &off);
                const bytes = longBytes(b, &off);
                break :blk .{ .store_set = .{ .key = head.key, .ok_tag = head.ok, .err_tag = head.err, .scope = scope, .store_key = store_key, .bytes = bytes } };
            },
            0x24 => blk: {
                const head = routedHead(b, &off);
                const scope = readU32(b, &off);
                const store_key = longBytes(b, &off);
                break :blk .{ .store_get = .{ .key = head.key, .ok_tag = head.ok, .err_tag = head.err, .scope = scope, .store_key = store_key } };
            },
            0x25 => blk: {
                const head = routedHead(b, &off);
                const scope = readU32(b, &off);
                const store_key = longBytes(b, &off);
                break :blk .{ .store_delete = .{ .key = head.key, .ok_tag = head.ok, .err_tag = head.err, .scope = scope, .store_key = store_key } };
            },
            0x26 => blk: {
                const head = routedHead(b, &off);
                const scope = readU32(b, &off);
                const prefix = longBytes(b, &off);
                const limit = readU32(b, &off);
                const after = longBytes(b, &off);
                break :blk .{ .store_scan = .{ .key = head.key, .ok_tag = head.ok, .err_tag = head.err, .scope = scope, .prefix = prefix, .limit = limit, .after = after } };
            },
            0x27 => blk: {
                const head = routedHead(b, &off);
                const scope = readU32(b, &off);
                const count = readU32(b, &off);
                const entries_start = off;
                for (0..count) |_| {
                    _ = longBytes(b, &off);
                    _ = longBytes(b, &off);
                }
                break :blk .{ .store_set_many = .{ .key = head.key, .ok_tag = head.ok, .err_tag = head.err, .scope = scope, .count = count, .entry_bytes = b[entries_start..off] } };
            },
            0x2B => blk: {
                const head = routedHead(b, &off);
                break :blk .{ .append_file = .{ .key = head.key, .ok_tag = head.ok, .err_tag = head.err, .path = longBytes(b, &off), .bytes = longBytes(b, &off) } };
            },
            0x2C => blk: {
                const head = routedHead(b, &off);
                break :blk .{ .stat_file = .{ .key = head.key, .ok_tag = head.ok, .err_tag = head.err, .path = longBytes(b, &off) } };
            },
            0x2D => blk: {
                const key = shortBytes(b, &off);
                const chunk_tag = b[off];
                const done_tag = b[off + 1];
                const err_tag = b[off + 2];
                off += 3;
                break :blk .{ .read_file_stream = .{ .key = key, .chunk_tag = chunk_tag, .done_tag = done_tag, .err_tag = err_tag, .path = longBytes(b, &off) } };
            },
            0x2E => blk: {
                const head = routedHead(b, &off);
                break :blk .{ .write_file_stream = .{ .key = head.key, .ok_tag = head.ok, .err_tag = head.err, .path = longBytes(b, &off) } };
            },
            0x2F => blk: {
                const head = routedHead(b, &off);
                break :blk .{ .write_file_chunk = .{ .key = head.key, .ok_tag = head.ok, .err_tag = head.err, .bytes = longBytes(b, &off) } };
            },
            0x30 => blk: {
                const head = routedHead(b, &off);
                break :blk .{ .write_file_close = .{ .key = head.key, .ok_tag = head.ok, .err_tag = head.err } };
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

fn readU32(b: []const u8, off: *usize) u32 {
    const value = std.mem.readInt(u32, b[off.*..][0..4], .little);
    off.* += 4;
    return value;
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

test "window_hide and dock_presence decode, alone and inside a batch" {
    const hidden = findOp(&.{ 0x21, 4, 'm', 'a', 'i', 'n' }, .window_hide) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("main", hidden.label);

    const dock = findOp(&.{ 0x22, 0 }, .dock_presence) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!dock.visible);

    const batch = [_]u8{ 0x21, 3, 'h', 'u', 'd', 0x22, 1, 0x02, 9 };
    var iter = CmdIter.init(&batch);
    try std.testing.expectEqualStrings("hud", (iter.next() orelse return error.TestUnexpectedResult).window_hide.label);
    try std.testing.expect((iter.next() orelse return error.TestUnexpectedResult).dock_presence.visible);
    try std.testing.expectEqual(@as(u8, 9), (iter.next() orelse return error.TestUnexpectedResult).now.msg_tag);
    try std.testing.expectEqual(@as(?Op, null), iter.next());
}

test "record store command records decode and advance exactly" {
    const batch = [_]u8{
        0x23, 1, 'r', 2,   3,    0, 0,   0, 0, 1,    0,  0, 0,   'k', 1, 0, 0, 0, 'v',
        0x26, 0, 4,   5,   0,    0, 0,   0, 2, 0,    0,  0, 'p', '/', 7, 0, 0, 0, 1,
        0,    0, 0,   'a', 0x27, 1, 'b', 6, 7, 0,    0,  0, 0,   1,   0, 0, 0, 1, 0,
        0,    0, 'x', 2,   0,    0, 0,   8, 9, 0x02, 10,
    };
    var iter = CmdIter.init(&batch);
    const set = (iter.next() orelse return error.TestUnexpectedResult).store_set;
    try std.testing.expectEqualStrings("r", set.key);
    try std.testing.expectEqualStrings("k", set.store_key);
    try std.testing.expectEqualSlices(u8, "v", set.bytes);
    const scan = (iter.next() orelse return error.TestUnexpectedResult).store_scan;
    try std.testing.expectEqualStrings("p/", scan.prefix);
    try std.testing.expectEqual(@as(u32, 7), scan.limit);
    try std.testing.expectEqualStrings("a", scan.after);
    const many = (iter.next() orelse return error.TestUnexpectedResult).store_set_many;
    try std.testing.expectEqual(@as(u32, 1), many.count);
    try std.testing.expectEqualStrings("x", many.entry(0).key);
    try std.testing.expectEqualSlices(u8, &.{ 8, 9 }, many.entry(0).bytes);
    try std.testing.expectEqual(@as(u8, 10), (iter.next() orelse return error.TestUnexpectedResult).now.msg_tag);
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

test "the channel records decode, alone and inside a batch" {
    // channel_open: [op 0x15][key f64 LE][event_tag u8][max_pending u8].
    var open_bytes: [11]u8 = undefined;
    open_bytes[0] = 0x15;
    open_bytes[1..9].* = @bitCast(@as(f64, 41));
    open_bytes[9] = 5; // event_tag
    open_bytes[10] = 7; // max_pending
    const opened = findOp(&open_bytes, .channel_open) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 41), opened.key);
    try std.testing.expectEqual(@as(u8, 5), opened.event_tag);
    try std.testing.expectEqual(@as(u8, 7), opened.max_pending);

    // channel_close: [op 0x16][key f64 LE].
    var close_bytes: [9]u8 = undefined;
    close_bytes[0] = 0x16;
    close_bytes[1..9].* = @bitCast(@as(f64, 41));
    const closed = findOp(&close_bytes, .channel_close) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 41), closed.key);

    // A batch of open + close + a trailing now record: each record must
    // advance the iterator exactly its own length (eleven bytes, then
    // nine) for the tail to decode.
    var batch: [22]u8 = undefined;
    batch[0..11].* = open_bytes;
    batch[11..20].* = close_bytes;
    batch[20] = 0x02;
    batch[21] = 7;
    var iter = CmdIter.init(&batch);
    const first = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 41), first.channel_open.key);
    const second = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 41), second.channel_close.key);
    const third = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 7), third.now.msg_tag);
    try std.testing.expectEqual(@as(?Op, null), iter.next());
}

test "typed request metadata and atomic streaming service records decode" {
    const a = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);

    try bytes.append(a, 0x05);
    try bytes.append(a, 5);
    try bytes.appendSlice(a, "parse");
    try bytes.append(a, 3);
    try bytes.appendSlice(a, "one");
    try bytes.appendSlice(a, &.{ 4, 5, 1, 2, 0, 0, 0, 'o', 'k' });
    const request = findOp(bytes.items, .request) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("parse", request.name);
    try std.testing.expect(request.typed_service);
    try std.testing.expectEqualStrings("ok", request.payload);

    bytes.clearRetainingCapacity();
    try bytes.append(a, 0x28);
    try bytes.appendSlice(a, &@as([8]u8, @bitCast(@as(f64, 79))));
    try bytes.appendSlice(a, &.{ 6, 3 });
    try bytes.append(a, 6);
    try bytes.appendSlice(a, "stream");
    try bytes.append(a, 3);
    try bytes.appendSlice(a, "two");
    try bytes.appendSlice(a, &.{ 7, 8, 3, 0, 0, 0, 1, 2, 3 });
    const stream = findOp(bytes.items, .service_stream_request) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 79), stream.channel_key);
    try std.testing.expectEqual(@as(u8, 6), stream.event_tag);
    try std.testing.expectEqual(@as(u8, 3), stream.max_pending);
    try std.testing.expectEqualStrings("stream", stream.name);
    try std.testing.expectEqualStrings("two", stream.key);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, stream.payload);
}

test "the audio capture records decode and advance a batch exactly" {
    var start: [16]u8 = undefined;
    start[0] = 0x1E;
    start[1..9].* = @bitCast(@as(f64, 91));
    start[9] = 1; // system
    std.mem.writeInt(u32, start[10..14], 24_000, .little);
    start[14] = 2;
    start[15] = 6;
    const opened = findOp(&start, .audio_capture_start) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 91), opened.key);
    try std.testing.expectEqual(@as(u8, 1), opened.source);
    try std.testing.expectEqual(@as(u32, 24_000), opened.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), opened.channels);
    try std.testing.expectEqual(@as(u8, 6), opened.event_tag);

    var stop: [9]u8 = undefined;
    stop[0] = 0x1F;
    stop[1..9].* = @bitCast(@as(f64, 91));
    var batch: [27]u8 = undefined;
    batch[0..16].* = start;
    batch[16..25].* = stop;
    batch[25..27].* = .{ 0x02, 7 };
    var iter = CmdIter.init(&batch);
    _ = iter.next() orelse return error.TestUnexpectedResult;
    const closed = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 91), closed.audio_capture_stop.key);
    try std.testing.expectEqual(@as(u8, 7), (iter.next() orelse return error.TestUnexpectedResult).now.msg_tag);
    try std.testing.expectEqual(@as(?Op, null), iter.next());
}

test "the pty records decode, alone and inside a batch" {
    const a = std.testing.allocator;

    // pty_spawn: [op 0x19][key][event_tag][cols f64 LE][rows f64 LE]
    // [term][argc]([arg len u32 LE][arg])* — the bytes rt.zig's
    // cmdPtySpawn pins (the same layout
    // packages/core/test/effects.test.ts asserts).
    var spawn_bytes: std.ArrayList(u8) = .empty;
    defer spawn_bytes.deinit(a);
    try spawn_bytes.append(a, 0x19);
    try spawn_bytes.append(a, 5);
    try spawn_bytes.appendSlice(a, "shell");
    try spawn_bytes.append(a, 4); // event_tag
    try spawn_bytes.appendSlice(a, &@as([8]u8, @bitCast(@as(f64, 120))));
    try spawn_bytes.appendSlice(a, &@as([8]u8, @bitCast(@as(f64, 30))));
    try spawn_bytes.append(a, 14);
    try spawn_bytes.appendSlice(a, "xterm-256color");
    try spawn_bytes.append(a, 2); // argc
    try spawn_bytes.appendSlice(a, &.{ 8, 0, 0, 0 });
    try spawn_bytes.appendSlice(a, "/bin/zsh");
    try spawn_bytes.appendSlice(a, &.{ 2, 0, 0, 0 });
    try spawn_bytes.appendSlice(a, "-l");
    const spawned = findOp(spawn_bytes.items, .pty_spawn) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("shell", spawned.key);
    try std.testing.expectEqual(@as(u8, 4), spawned.event_tag);
    try std.testing.expectEqual(@as(f64, 120), spawned.cols);
    try std.testing.expectEqual(@as(f64, 30), spawned.rows);
    try std.testing.expectEqualStrings("xterm-256color", spawned.term);
    try std.testing.expectEqual(@as(u8, 2), spawned.arg_count);
    try std.testing.expectEqualStrings("/bin/zsh", spawned.arg(0));
    try std.testing.expectEqualStrings("-l", spawned.arg(1));

    // pty_write [0x1A][key][bytes u32-len], pty_resize [0x1B][key]
    // [cols f64 LE][rows f64 LE], pty_kill [0x1C][key], notification
    // [0x1D][title][subtitle][body], and a trailing now record in one batch:
    // each record must advance the iterator exactly its own length for the
    // tail to decode.
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(a);
    try batch.append(a, 0x1A);
    try batch.append(a, 5);
    try batch.appendSlice(a, "shell");
    try batch.appendSlice(a, &.{ 3, 0, 0, 0 });
    try batch.appendSlice(a, "ls\n");
    try batch.append(a, 0x1B);
    try batch.append(a, 5);
    try batch.appendSlice(a, "shell");
    try batch.appendSlice(a, &@as([8]u8, @bitCast(@as(f64, 100))));
    try batch.appendSlice(a, &@as([8]u8, @bitCast(@as(f64, 40))));
    try batch.append(a, 0x1C);
    try batch.append(a, 5);
    try batch.appendSlice(a, "shell");
    try batch.append(a, 0x1D);
    try batch.appendSlice(a, &.{ 5, 0, 0, 0 });
    try batch.appendSlice(a, "Ready");
    try batch.appendSlice(a, &.{ 3, 0, 0, 0 });
    try batch.appendSlice(a, "SDK");
    try batch.appendSlice(a, &.{ 4, 0, 0, 0 });
    try batch.appendSlice(a, "Done");
    try batch.appendSlice(a, &.{ 0x02, 7 });
    var iter = CmdIter.init(batch.items);
    const wrote = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("shell", wrote.pty_write.key);
    try std.testing.expectEqualStrings("ls\n", wrote.pty_write.bytes);
    const resized = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 100), resized.pty_resize.cols);
    try std.testing.expectEqual(@as(f64, 40), resized.pty_resize.rows);
    const killed = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("shell", killed.pty_kill.key);
    const notification = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Ready", notification.show_notification.title);
    try std.testing.expectEqualStrings("SDK", notification.show_notification.subtitle);
    try std.testing.expectEqualStrings("Done", notification.show_notification.body);
    const tail = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 7), tail.now.msg_tag);
    try std.testing.expectEqual(@as(?Op, null), iter.next());
}

test "streaming fetch decodes its routes and limits" {
    const a = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);

    try bytes.append(a, 0x20);
    try bytes.append(a, 4);
    try bytes.appendSlice(a, "chat");
    try bytes.appendSlice(a, &.{ 7, 8, 9, 1 });
    try bytes.appendSlice(a, &.{ 0x88, 0x13, 0, 0 }); // 5000 ms
    try bytes.appendSlice(a, &.{ 0, 0x20, 0, 0 }); // 8192 bytes
    try bytes.appendSlice(a, &.{ 15, 0, 0, 0 });
    try bytes.appendSlice(a, "https://ai.test");
    try bytes.append(a, 1);
    try bytes.append(a, 6);
    try bytes.appendSlice(a, "accept");
    try bytes.appendSlice(a, &.{ 17, 0, 0, 0 });
    try bytes.appendSlice(a, "text/event-stream");
    try bytes.appendSlice(a, &.{ 2, 0, 0, 0 });
    try bytes.appendSlice(a, "{}");

    const stream = findOp(bytes.items, .fetch_stream) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("chat", stream.key);
    try std.testing.expectEqual(@as(u8, 7), stream.line_tag);
    try std.testing.expectEqual(@as(u8, 8), stream.ok_tag);
    try std.testing.expectEqual(@as(u8, 9), stream.err_tag);
    try std.testing.expectEqual(@as(u8, 1), stream.method);
    try std.testing.expectEqual(@as(u32, 5000), stream.timeout_ms);
    try std.testing.expectEqual(@as(u32, 8192), stream.max_line_bytes);
    try std.testing.expectEqualStrings("https://ai.test", stream.url);
    try std.testing.expectEqual(@as(u8, 1), stream.header_count);
    try std.testing.expectEqualStrings("{}", stream.body);
}
