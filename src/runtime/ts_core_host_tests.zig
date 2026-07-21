//! Bridge coverage for `TsCoreHost` against a hand-written core that
//! replicates the transpiler's emitted ABI (rt kernel, commit walker,
//! `UpdateResult`/`InitResult`, wire-encoded commands and
//! subscriptions). Hand-encoding the wire records here pins the v2
//! byte layout independently of the rt builders that normally produce
//! it; the transpiled-fixture end-to-end suite (tests/ts-core) drives
//! the same bridge with genuinely emitted code through a full UiApp.
//! Everything runs the effects channel directly with the fake executor
//! — deterministic request/feed round trips, no platform.

const std = @import("std");
const effects_mod = @import("effects.zig");
const runtime_clock = @import("clock.zig");
const ts_core_host = @import("ts_core_host.zig");

// ------------------------------------------------------ the mini core
//
// The emitted-core ABI in miniature: a two-region kernel, a poller
// model, and an update that exercises every wire record. Cmd/Sub bytes
// are hand-encoded to the documented v2 layout. Polling starts OFF so
// the real-executor tests below (which bind no platform timer service)
// never arm a timer; the e2e suite covers boot-time subscriptions
// through a full UiApp with live null-platform services.

const mini_core = struct {
    pub const rt = struct {
        var frame_buf: [64 * 1024]u8 align(16) = undefined;
        var frame_off: usize = 0;
        var heap_buf: [64 * 1024]u8 align(16) = undefined;
        var heap_off: usize = 0;

        pub fn frameAlloc(comptime T: type, n: usize) []T {
            const aligned = std.mem.alignForward(usize, frame_off, @alignOf(T));
            const next = aligned + n * @sizeOf(T);
            if (next > frame_buf.len) @panic("mini core: frame overflow");
            frame_off = next;
            const ptr: [*]T = @ptrCast(@alignCast(frame_buf[aligned..].ptr));
            return ptr[0..n];
        }

        pub fn frameReset() void {
            frame_off = 0;
        }

        pub fn resetAll() void {
            frame_off = 0;
            heap_off = 0;
        }

        fn inFrame(addr: usize) bool {
            const base = @intFromPtr(&frame_buf);
            return addr >= base and addr < base + frame_buf.len;
        }

        fn heapAlloc(comptime T: type, n: usize) []T {
            const aligned = std.mem.alignForward(usize, heap_off, @alignOf(T));
            const next = aligned + n * @sizeOf(T);
            if (next > heap_buf.len) @panic("mini core: heap overflow");
            heap_off = next;
            const ptr: [*]T = @ptrCast(@alignCast(heap_buf[aligned..].ptr));
            return ptr[0..n];
        }
    };

    /// The audio event state union, deliberately declared in an order
    /// DIFFERENT from the engine's `EffectAudioEventKind`: the bridge
    /// matches members by NAME, so the app's declaration order is free.
    pub const AudioState = enum { spectrum, loaded, completed, position, rejected, failed };

    /// The channel event states, shuffled off the engine order for the
    /// same by-NAME matching proof.
    pub const ChannelState = enum { rejected, data, closed };

    pub const Model = struct {
        polling: bool,
        fast: bool,
        ticks: i64,
        last_ms: f64,
        stamp_ms: f64,
        errs: i64,
        saved: bool,
        code: i64,
        status: []const u8,
        last_err: []const u8,
        // Spawn stream mirrors.
        line_count: i64,
        last_line: []const u8,
        exit_code: i64,
        output: []const u8,
        // Audio stream mirrors.
        audio_state: AudioState,
        position_ms: f64,
        duration_ms: f64,
        playing: bool,
        buffering: bool,
        bands: []const u8,
        audio_events: i64,
        // Channel event mirrors.
        chan_state: ChannelState,
        chan_key: f64,
        chan_bytes: []const u8,
        chan_dropped_pending: f64,
        chan_dropped_total: f64,
        chan_events: i64,
    };

    pub const Msg = union(enum) {
        toggle, // 0: pure — pauses/resumes the subscription
        speed, // 1: pure — switches the tick interval (re-arm case)
        refresh, // 2: keyed request (replaces a live "status" request)
        pair, // 3: two unkeyed requests in one batch (ordering)
        abort, // 4: cancel "status"
        stamp, // 5: Cmd.now -> .stamped
        note, // 6: persist ++ host(scalars) ++ host_bytes
        loaded: []const u8, // 7: ok route (bytes)
        failed: []const u8, // 8: err route (reason bytes)
        tick: f64, // 9: subscription arm
        stamped: f64, // 10: now arm / delay arm
        save_file, // 11: write_file "save" -> wrote/failed
        wrote, // 12: write_file's payload-less ok route
        load_file, // 13: read_file "load" -> loaded/failed
        get, // 14: fetch "get" -> fetched/failed
        fetched: struct { status: i64, body: []const u8 }, // 15: fetch ok record
        copy, // 16: clip_write (fire-and-forget)
        paste, // 17: clip_read "paste" -> loaded/failed
        arm_delay, // 18: delay "boom" 250ms -> stamped
        halt, // 19: cancel "boom"
        drop_load, // 20: cancel "load"
        dup_load, // 21: two read_file "load" in one batch (dup reject)
        run_lines, // 22: spawn "job" lines -> got_line/job_done/failed
        run_quiet, // 23: spawn "job" lines, NO line arm (0xFF)
        run_collect, // 24: spawn "job" collect -> sampled/failed
        got_line: []const u8, // 25: spawn line arm
        job_done: i64, // 26: line-mode exit arm (the code)
        sampled: struct { code: i64, output: []const u8 }, // 27: collect exit record
        stop_job, // 28: cancel "job" (mid-stream)
        dup_job, // 29: two spawns under one key in one batch
        play, // 30: audio_play "track" (local path) -> audio_evt
        play_stream, // 31: audio_play "track" (url + cache + expected)
        audio_evt: struct { // 32: the six-field audio event arm (the
            // emitted shape — payload fields keep their TS names)
            state: AudioState,
            positionMs: f64,
            durationMs: f64,
            playing: bool,
            buffering: bool,
            bands: []const u8,
        },
        pause_it, // 33: audio_ctl pause "track"
        resume_it, // 34: audio_ctl resume "track"
        stop_it, // 35: audio_ctl stop "track"
        seek_it, // 36: audio_ctl seek "track" 45000ms
        vol_it, // 37: audio_ctl volume "track" 0.25
        ctl_stray, // 38: audio_ctl pause "other" (key gate no-op)
        play_bare_url, // 39: audio_play "track" (url, NO cache path)
        drop_save, // 40: cancel "save" (silent write_file drop)
        drop_get, // 41: cancel "get" (silent fetch drop)
        drop_paste, // 42: cancel "paste" (silent clip_read drop)
        open_win, // 43: window_show "player" (the tray Open consequence)
        quit_app, // 44: quit_app (the tray Quit consequence)
        open_chan, // 45: channel_open key 41 -> chan_evt
        close_chan, // 46: channel_close key 41
        chan_evt: struct { // 47: the five-field channel event arm (the
            // emitted shape — payload fields keep their TS names)
            key: f64,
            state: ChannelState,
            bytes: []const u8,
            droppedPending: f64,
            droppedTotal: f64,
        },
    };

    pub const InitResult = struct { model: *const Model, cmd: []const u8 };
    pub const UpdateResult = struct { model: *const Model, cmd: []const u8 };

    fn frameCreate(value: Model) *Model {
        const slot = rt.frameAlloc(Model, 1);
        slot[0] = value;
        return &slot[0];
    }

    pub fn initialModel() InitResult {
        return .{
            .model = frameCreate(.{
                .polling = false,
                .fast = false,
                .ticks = 0,
                .last_ms = -1,
                .stamp_ms = -1,
                .errs = 0,
                .saved = false,
                .code = -1,
                .status = "",
                .last_err = "",
                .line_count = 0,
                .last_line = "",
                .exit_code = -1,
                .output = "",
                .audio_state = .rejected,
                .position_ms = -1,
                .duration_ms = -1,
                .playing = false,
                .buffering = false,
                .bands = "",
                .audio_events = 0,
                .chan_state = .closed,
                .chan_key = -1,
                .chan_bytes = "",
                .chan_dropped_pending = -1,
                .chan_dropped_total = -1,
                .chan_events = 0,
            }),
            .cmd = cmdRequest("status.read", "status", 7, 8, "boot"),
        };
    }

    pub fn update(model: *const Model, msg: Msg) UpdateResult {
        switch (msg) {
            .toggle => {
                const out = frameCreate(model.*);
                out.polling = !model.polling;
                return .{ .model = out, .cmd = "" };
            },
            .speed => {
                const out = frameCreate(model.*);
                out.fast = !model.fast;
                return .{ .model = out, .cmd = "" };
            },
            .refresh => return .{ .model = model, .cmd = cmdRequest("status.read", "status", 7, 8, model.status) },
            .pair => {
                const first = cmdRequest("a.read", "", 7, 8, "1");
                const second = cmdRequest("b.read", "", 7, 8, "2");
                const out = rt.frameAlloc(u8, first.len + second.len);
                @memcpy(out[0..first.len], first);
                @memcpy(out[first.len..], second);
                return .{ .model = model, .cmd = out };
            },
            .abort => return .{ .model = model, .cmd = cmdCancel("status") },
            .stamp => return .{ .model = model, .cmd = cmdNow(10) },
            .note => {
                const persist = [_]u8{0x01};
                const host = cmdHost("gain.set", &.{ 0.5, 2.0 });
                const host_bytes = cmdHostBytes("blob.put", "hi");
                const out = rt.frameAlloc(u8, persist.len + host.len + host_bytes.len);
                @memcpy(out[0..1], &persist);
                @memcpy(out[1..][0..host.len], host);
                @memcpy(out[1 + host.len ..], host_bytes);
                return .{ .model = model, .cmd = out };
            },
            .loaded => |body| {
                const out = frameCreate(model.*);
                out.status = body;
                return .{ .model = out, .cmd = "" };
            },
            .failed => |why| {
                const out = frameCreate(model.*);
                out.errs = model.errs + 1;
                out.last_err = why;
                return .{ .model = out, .cmd = "" };
            },
            .save_file => return .{ .model = model, .cmd = cmdWriteFile("save", 12, 8, "notes.bin", model.status) },
            .wrote => {
                const out = frameCreate(model.*);
                out.saved = true;
                return .{ .model = out, .cmd = "" };
            },
            .load_file => return .{ .model = model, .cmd = cmdReadFile("load", 7, 8, "notes.bin") },
            .get => {
                const headers = [_]FetchHeader{.{ .name = "accept", .value = "text/plain" }};
                return .{ .model = model, .cmd = cmdFetch("get", 15, 8, 1, 0, "https://status.test/q", &headers, "ask") };
            },
            .fetched => |response| {
                const out = frameCreate(model.*);
                out.code = response.status;
                out.status = response.body;
                return .{ .model = out, .cmd = "" };
            },
            .copy => return .{ .model = model, .cmd = cmdClipWrite("hi") },
            .paste => return .{ .model = model, .cmd = cmdClipRead("paste", 7, 8) },
            .arm_delay => return .{ .model = model, .cmd = cmdDelay("boom", 250, 10) },
            .halt => return .{ .model = model, .cmd = cmdCancel("boom") },
            .drop_load => return .{ .model = model, .cmd = cmdCancel("load") },
            .dup_load => {
                const first = cmdReadFile("load", 7, 8, "notes.bin");
                const second = cmdReadFile("load", 7, 8, "notes.bin");
                const out = rt.frameAlloc(u8, first.len + second.len);
                @memcpy(out[0..first.len], first);
                @memcpy(out[first.len..], second);
                return .{ .model = model, .cmd = out };
            },
            .tick => |at| {
                const out = frameCreate(model.*);
                out.ticks = model.ticks + 1;
                out.last_ms = at;
                return .{ .model = out, .cmd = "" };
            },
            .stamped => |at| {
                const out = frameCreate(model.*);
                out.stamp_ms = at;
                return .{ .model = out, .cmd = "" };
            },
            .run_lines => return .{ .model = model, .cmd = cmdSpawn("job", 25, 26, 8, 0, &.{ "/bin/probe", "--fast" }, "feed me") },
            .run_quiet => return .{ .model = model, .cmd = cmdSpawn("job", 0xFF, 26, 8, 0, &.{"/bin/quiet"}, "") },
            .run_collect => return .{ .model = model, .cmd = cmdSpawn("job", 0xFF, 27, 8, 1, &.{ "/bin/ps", "-axo" }, "") },
            .got_line => |line| {
                const out = frameCreate(model.*);
                out.line_count = model.line_count + 1;
                out.last_line = line;
                return .{ .model = out, .cmd = "" };
            },
            .job_done => |code| {
                const out = frameCreate(model.*);
                out.exit_code = code;
                return .{ .model = out, .cmd = "" };
            },
            .sampled => |result| {
                const out = frameCreate(model.*);
                out.exit_code = result.code;
                out.output = result.output;
                return .{ .model = out, .cmd = "" };
            },
            .stop_job => return .{ .model = model, .cmd = cmdCancel("job") },
            .dup_job => {
                const first = cmdSpawn("job", 0xFF, 26, 8, 0, &.{"/bin/one"}, "");
                const second = cmdSpawn("job", 0xFF, 26, 8, 0, &.{"/bin/two"}, "");
                const out = rt.frameAlloc(u8, first.len + second.len);
                @memcpy(out[0..first.len], first);
                @memcpy(out[first.len..], second);
                return .{ .model = model, .cmd = out };
            },
            .play => return .{ .model = model, .cmd = cmdAudioPlay("track", 32, "music/a.mp3", "", "", 0) },
            .play_stream => return .{ .model = model, .cmd = cmdAudioPlay("track", 32, "", "https://cdn.test/a.mp3", "cache/a.mp3", 4096) },
            .audio_evt => |event| {
                const out = frameCreate(model.*);
                out.audio_state = event.state;
                out.position_ms = event.positionMs;
                out.duration_ms = event.durationMs;
                out.playing = event.playing;
                out.buffering = event.buffering;
                out.bands = event.bands;
                out.audio_events = model.audio_events + 1;
                return .{ .model = out, .cmd = "" };
            },
            .pause_it => return .{ .model = model, .cmd = cmdAudioCtl("track", 0, 0) },
            .resume_it => return .{ .model = model, .cmd = cmdAudioCtl("track", 1, 0) },
            .stop_it => return .{ .model = model, .cmd = cmdAudioCtl("track", 2, 0) },
            .seek_it => return .{ .model = model, .cmd = cmdAudioCtl("track", 3, 45_000) },
            .vol_it => return .{ .model = model, .cmd = cmdAudioCtl("track", 4, 0.25) },
            .ctl_stray => return .{ .model = model, .cmd = cmdAudioCtl("other", 0, 0) },
            .play_bare_url => return .{ .model = model, .cmd = cmdAudioPlay("track", 32, "", "https://cdn.test/b.mp3", "", 0) },
            .drop_save => return .{ .model = model, .cmd = cmdCancel("save") },
            .drop_get => return .{ .model = model, .cmd = cmdCancel("get") },
            .drop_paste => return .{ .model = model, .cmd = cmdCancel("paste") },
            .open_win => return .{ .model = model, .cmd = cmdWindowShow("player") },
            .quit_app => return .{ .model = model, .cmd = cmdQuitApp() },
            .open_chan => return .{ .model = model, .cmd = cmdChannelOpen(41, 47) },
            .close_chan => return .{ .model = model, .cmd = cmdChannelClose(41) },
            .chan_evt => |event| {
                const out = frameCreate(model.*);
                out.chan_state = event.state;
                out.chan_key = event.key;
                out.chan_bytes = event.bytes;
                out.chan_dropped_pending = event.droppedPending;
                out.chan_dropped_total = event.droppedTotal;
                out.chan_events = model.chan_events + 1;
                return .{ .model = out, .cmd = "" };
            },
        }
    }

    pub fn subscriptions(model: *const Model) []const u8 {
        if (!model.polling) return "";
        return subTimer("tick", if (model.fast) 40 else 100, 9);
    }

    pub fn commitModelRoot(next: *const Model) *const Model {
        if (!rt.inFrame(@intFromPtr(next))) return next;
        const out = rt.heapAlloc(Model, 1);
        out[0] = next.*;
        out[0].status = commitBytes(next.status);
        out[0].last_err = commitBytes(next.last_err);
        out[0].last_line = commitBytes(next.last_line);
        out[0].output = commitBytes(next.output);
        out[0].bands = commitBytes(next.bands);
        out[0].chan_bytes = commitBytes(next.chan_bytes);
        return &out[0];
    }

    fn commitBytes(bytes: []const u8) []const u8 {
        if (bytes.len == 0 or !rt.inFrame(@intFromPtr(bytes.ptr))) return bytes;
        const out = rt.heapAlloc(u8, bytes.len);
        @memcpy(out, bytes);
        return out;
    }

    // Hand-encoded v2 wire records (rt.zig's documented layout).

    fn cmdNow(msg_tag: u8) []const u8 {
        const out = rt.frameAlloc(u8, 2);
        out[0] = 0x02;
        out[1] = msg_tag;
        return out;
    }

    fn cmdHost(name: []const u8, args: []const f64) []const u8 {
        const out = rt.frameAlloc(u8, 3 + name.len + args.len * 8);
        out[0] = 0x03;
        out[1] = @intCast(name.len);
        @memcpy(out[2..][0..name.len], name);
        out[2 + name.len] = @intCast(args.len);
        for (args, 0..) |arg, i| {
            std.mem.writeInt(u64, out[3 + name.len + i * 8 ..][0..8], @bitCast(arg), .little);
        }
        return out;
    }

    fn cmdHostBytes(name: []const u8, payload: []const u8) []const u8 {
        const out = rt.frameAlloc(u8, 2 + name.len + 4 + payload.len);
        out[0] = 0x04;
        out[1] = @intCast(name.len);
        @memcpy(out[2..][0..name.len], name);
        std.mem.writeInt(u32, out[2 + name.len ..][0..4], @intCast(payload.len), .little);
        @memcpy(out[2 + name.len + 4 ..][0..payload.len], payload);
        return out;
    }

    fn cmdRequest(name: []const u8, key: []const u8, ok_tag: u8, err_tag: u8, payload: []const u8) []const u8 {
        const out = rt.frameAlloc(u8, 2 + name.len + 1 + key.len + 2 + 4 + payload.len);
        out[0] = 0x05;
        out[1] = @intCast(name.len);
        @memcpy(out[2..][0..name.len], name);
        var off: usize = 2 + name.len;
        out[off] = @intCast(key.len);
        @memcpy(out[off + 1 ..][0..key.len], key);
        off += 1 + key.len;
        out[off] = ok_tag;
        out[off + 1] = err_tag;
        std.mem.writeInt(u32, out[off + 2 ..][0..4], @intCast(payload.len), .little);
        @memcpy(out[off + 6 ..][0..payload.len], payload);
        return out;
    }

    fn cmdCancel(key: []const u8) []const u8 {
        const out = rt.frameAlloc(u8, 2 + key.len);
        out[0] = 0x06;
        out[1] = @intCast(key.len);
        @memcpy(out[2..][0..key.len], key);
        return out;
    }

    const FetchHeader = struct { name: []const u8, value: []const u8 };

    fn writeRoutedHead(out: []u8, op: u8, key: []const u8, ok_tag: u8, err_tag: u8) usize {
        out[0] = op;
        out[1] = @intCast(key.len);
        @memcpy(out[2..][0..key.len], key);
        out[2 + key.len] = ok_tag;
        out[3 + key.len] = err_tag;
        return 4 + key.len;
    }

    fn writeLongBytes(out: []u8, at: usize, bytes: []const u8) usize {
        std.mem.writeInt(u32, out[at..][0..4], @intCast(bytes.len), .little);
        @memcpy(out[at + 4 ..][0..bytes.len], bytes);
        return at + 4 + bytes.len;
    }

    fn cmdReadFile(key: []const u8, ok_tag: u8, err_tag: u8, file_path: []const u8) []const u8 {
        const out = rt.frameAlloc(u8, 4 + key.len + 4 + file_path.len);
        var off = writeRoutedHead(out, 0x07, key, ok_tag, err_tag);
        off = writeLongBytes(out, off, file_path);
        return out;
    }

    fn cmdWriteFile(key: []const u8, ok_tag: u8, err_tag: u8, file_path: []const u8, bytes: []const u8) []const u8 {
        const out = rt.frameAlloc(u8, 4 + key.len + 4 + file_path.len + 4 + bytes.len);
        var off = writeRoutedHead(out, 0x08, key, ok_tag, err_tag);
        off = writeLongBytes(out, off, file_path);
        off = writeLongBytes(out, off, bytes);
        return out;
    }

    fn cmdFetch(key: []const u8, ok_tag: u8, err_tag: u8, method: u8, timeout_ms: u32, url: []const u8, headers: []const FetchHeader, body: []const u8) []const u8 {
        var header_bytes: usize = 0;
        for (headers) |h| header_bytes += 1 + h.name.len + 4 + h.value.len;
        const out = rt.frameAlloc(u8, 4 + key.len + 1 + 4 + 4 + url.len + 1 + header_bytes + 4 + body.len);
        var off = writeRoutedHead(out, 0x09, key, ok_tag, err_tag);
        out[off] = method;
        std.mem.writeInt(u32, out[off + 1 ..][0..4], timeout_ms, .little);
        off += 5;
        off = writeLongBytes(out, off, url);
        out[off] = @intCast(headers.len);
        off += 1;
        for (headers) |h| {
            out[off] = @intCast(h.name.len);
            @memcpy(out[off + 1 ..][0..h.name.len], h.name);
            off += 1 + h.name.len;
            off = writeLongBytes(out, off, h.value);
        }
        off = writeLongBytes(out, off, body);
        return out;
    }

    fn cmdClipWrite(bytes: []const u8) []const u8 {
        const out = rt.frameAlloc(u8, 1 + 4 + bytes.len);
        out[0] = 0x0A;
        _ = writeLongBytes(out, 1, bytes);
        return out;
    }

    fn cmdClipRead(key: []const u8, ok_tag: u8, err_tag: u8) []const u8 {
        const out = rt.frameAlloc(u8, 4 + key.len);
        _ = writeRoutedHead(out, 0x0B, key, ok_tag, err_tag);
        return out;
    }

    fn cmdDelay(key: []const u8, after_ms: f64, msg_tag: u8) []const u8 {
        const out = rt.frameAlloc(u8, 2 + key.len + 8 + 1);
        out[0] = 0x0C;
        out[1] = @intCast(key.len);
        @memcpy(out[2..][0..key.len], key);
        std.mem.writeInt(u64, out[2 + key.len ..][0..8], @bitCast(after_ms), .little);
        out[2 + key.len + 8] = msg_tag;
        return out;
    }

    fn cmdSpawn(key: []const u8, line_tag: u8, exit_tag: u8, err_tag: u8, mode: u8, argv: []const []const u8, stdin: []const u8) []const u8 {
        var argv_bytes: usize = 0;
        for (argv) |arg| argv_bytes += 4 + arg.len;
        const out = rt.frameAlloc(u8, 2 + key.len + 5 + argv_bytes + 4 + stdin.len);
        out[0] = 0x0D;
        out[1] = @intCast(key.len);
        @memcpy(out[2..][0..key.len], key);
        var off: usize = 2 + key.len;
        out[off] = line_tag;
        out[off + 1] = exit_tag;
        out[off + 2] = err_tag;
        out[off + 3] = mode;
        out[off + 4] = @intCast(argv.len);
        off += 5;
        for (argv) |arg| off = writeLongBytes(out, off, arg);
        _ = writeLongBytes(out, off, stdin);
        return out;
    }

    fn cmdAudioPlay(key: []const u8, event_tag: u8, audio_path: []const u8, url: []const u8, cache_path: []const u8, expected_bytes: f64) []const u8 {
        const out = rt.frameAlloc(u8, 2 + key.len + 1 + 4 + audio_path.len + 4 + url.len + 4 + cache_path.len + 8);
        out[0] = 0x0E;
        out[1] = @intCast(key.len);
        @memcpy(out[2..][0..key.len], key);
        var off: usize = 2 + key.len;
        out[off] = event_tag;
        off += 1;
        off = writeLongBytes(out, off, audio_path);
        off = writeLongBytes(out, off, url);
        off = writeLongBytes(out, off, cache_path);
        std.mem.writeInt(u64, out[off..][0..8], @bitCast(expected_bytes), .little);
        return out;
    }

    fn cmdAudioCtl(key: []const u8, verb: u8, value: f64) []const u8 {
        const out = rt.frameAlloc(u8, 2 + key.len + 1 + 8);
        out[0] = 0x0F;
        out[1] = @intCast(key.len);
        @memcpy(out[2..][0..key.len], key);
        out[2 + key.len] = verb;
        std.mem.writeInt(u64, out[2 + key.len + 1 ..][0..8], @bitCast(value), .little);
        return out;
    }

    fn cmdWindowShow(label: []const u8) []const u8 {
        const out = rt.frameAlloc(u8, 2 + label.len);
        out[0] = 0x10;
        out[1] = @intCast(label.len);
        @memcpy(out[2..][0..label.len], label);
        return out;
    }

    fn cmdQuitApp() []const u8 {
        const out = rt.frameAlloc(u8, 1);
        out[0] = 0x11;
        return out;
    }

    fn cmdChannelOpen(key: f64, event_tag: u8) []const u8 {
        const out = rt.frameAlloc(u8, 1 + 8 + 1);
        out[0] = 0x15;
        std.mem.writeInt(u64, out[1..][0..8], @bitCast(key), .little);
        out[9] = event_tag;
        return out;
    }

    fn cmdChannelClose(key: f64) []const u8 {
        const out = rt.frameAlloc(u8, 1 + 8);
        out[0] = 0x16;
        std.mem.writeInt(u64, out[1..][0..8], @bitCast(key), .little);
        return out;
    }

    fn subTimer(key: []const u8, every_ms: f64, msg_tag: u8) []const u8 {
        const out = rt.frameAlloc(u8, 2 + key.len + 8 + 1);
        out[0] = 0x01;
        out[1] = @intCast(key.len);
        @memcpy(out[2..][0..key.len], key);
        std.mem.writeInt(u64, out[2 + key.len ..][0..8], @bitCast(every_ms), .little);
        out[2 + key.len + 8] = msg_tag;
        return out;
    }
};

const Host = ts_core_host.TsCoreHost(mini_core);
const Fx = Host.Fx;

const boot_request_key: u64 = ts_core_host.request_key_base + 0;
const tick_timer_key: u64 = ts_core_host.timer_key_base + 0;

// The channel is a large fixed-buffer struct; one static instance per
// test process keeps it off the test stack. Tests run sequentially.
var channel: Fx = undefined;

fn freshChannel() *Fx {
    channel = Fx.init(std.testing.allocator);
    channel.executor = .fake;
    return &channel;
}

// -------------------------------------------------------------- tests

test "init commits the boot model and issues the init request before the first frame" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    try std.testing.expect(!Host.model().polling);
    try std.testing.expectEqualStrings("", Host.model().status);

    // The boot command parked as a keyed host request, slot 0.
    try std.testing.expectEqual(@as(usize, 1), fx.pendingHostCount());
    const request = fx.pendingHostAt(0).?;
    try std.testing.expectEqual(boot_request_key, request.key);
    try std.testing.expectEqualStrings("status.read", request.name);
    try std.testing.expectEqualStrings("boot", request.payload);
}

test "a routed result dispatches the ok arm and the bytes commit into the model heap" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    try fx.feedHostResult(boot_request_key, true, "ready");
    Host.drain(fx);
    try std.testing.expectEqualStrings("ready", Host.model().status);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingHostCount());

    // The model's copy survives the engine retiring its drain scratch:
    // a later delivery (which frees the previous drain buffer) must not
    // disturb it. That is the frame-copy contract working.
    const kept = Host.model().status;
    Host.dispatch(fx, .refresh);
    try fx.feedHostResult(boot_request_key, false, "nope");
    Host.drain(fx);
    try std.testing.expectEqualStrings("ready", kept);
    try std.testing.expectEqual(@as(i64, 1), Host.model().errs);
    try std.testing.expectEqualStrings("ready", Host.model().status);
}

test "re-issuing a live key replaces the pending request and delivers exactly once" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    // The boot request (wire key "status") is in flight; refresh
    // re-issues the same wire key with a different payload.
    Host.dispatch(fx, .{ .loaded = "cache" });
    Host.dispatch(fx, .refresh);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingHostCount());
    const request = fx.pendingHostAt(0).?;
    try std.testing.expectEqual(boot_request_key, request.key);
    try std.testing.expectEqualStrings("cache", request.payload);

    try fx.feedHostResult(boot_request_key, true, "fresh");
    Host.drain(fx);
    try std.testing.expectEqualStrings("fresh", Host.model().status);
    // Exactly one terminal: the queue is empty and the key is retired.
    try std.testing.expect(fx.takeMsg() == null);
    try std.testing.expectError(error.EffectNotFound, fx.feedHostResult(boot_request_key, true, "late"));
}

test "cancel drops the in-flight request silently" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .abort);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingHostCount());
    try std.testing.expectError(error.EffectNotFound, fx.feedHostResult(boot_request_key, true, "late"));
    // Silent: nothing to drain, neither arm ran.
    try std.testing.expect(fx.takeMsg() == null);
    try std.testing.expectEqual(@as(i64, 0), Host.model().errs);
    try std.testing.expectEqualStrings("", Host.model().status);

    // A cancel that lands after the answer (fed, not yet drained) still
    // drops the result.
    Host.dispatch(fx, .refresh);
    try fx.feedHostResult(boot_request_key, true, "raced");
    Host.dispatch(fx, .abort);
    Host.drain(fx);
    try std.testing.expectEqualStrings("", Host.model().status);
    try std.testing.expectEqual(@as(i64, 0), Host.model().errs);
}

test "unkeyed requests dispatch in completion order" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);
    // Retire the boot request so the tables start clean.
    try fx.feedHostResult(boot_request_key, true, "");
    Host.drain(fx);

    Host.dispatch(fx, .pair);
    try std.testing.expectEqual(@as(usize, 2), fx.pendingHostCount());
    const first = fx.pendingHostAt(0).?;
    const second = fx.pendingHostAt(1).?;
    try std.testing.expectEqualStrings("a.read", first.name);
    try std.testing.expectEqualStrings("b.read", second.name);
    try std.testing.expect(first.key != second.key);

    // Answer out of issue order: completion order wins at the drain,
    // so the second answer is the last one the model absorbed.
    try fx.feedHostResult(second.key, true, "from-b");
    try fx.feedHostResult(first.key, true, "from-a");
    Host.drain(fx);
    try std.testing.expectEqualStrings("from-a", Host.model().status);
}

test "subscription reconcile arms, pauses, resumes, and re-arms on interval change" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingTimerCount());

    // New key arms the first free slot, repeating, wire interval.
    Host.dispatch(fx, .toggle);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingTimerCount());
    const timer = fx.pendingTimerAt(0).?;
    try std.testing.expectEqual(tick_timer_key, timer.key);
    try std.testing.expectEqual(@as(u64, 100), timer.interval_ms);
    try std.testing.expectEqual(effects_mod.TimerMode.repeating, timer.mode);

    // Missing key cancels; reappearing key re-arms into the same slot
    // (slot order, never hash order).
    Host.dispatch(fx, .toggle);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingTimerCount());
    Host.dispatch(fx, .toggle);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingTimerCount());
    try std.testing.expectEqual(tick_timer_key, fx.pendingTimerAt(0).?.key);

    // Interval change re-arms the same key in place.
    Host.dispatch(fx, .speed);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingTimerCount());
    try std.testing.expectEqual(tick_timer_key, fx.pendingTimerAt(0).?.key);
    try std.testing.expectEqual(@as(u64, 40), fx.pendingTimerAt(0).?.interval_ms);
}

test "timer fires dispatch the named arm with the fire time" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);
    Host.dispatch(fx, .toggle);

    try fx.fireTimer(tick_timer_key);
    try fx.fireTimer(tick_timer_key);
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 2), Host.model().ticks);
    // Fake fires carry timestamp 0 (the fake executor has no clock).
    try std.testing.expectEqual(@as(f64, 0), Host.model().last_ms);
}

test "Cmd.now dispatches synchronously with the journaled clock" {
    const fx = freshChannel();
    defer fx.deinit();
    var clock = runtime_clock.TestClock{};
    clock.setWallMs(1_234);
    fx.clock = clock.clock();

    const Capture = struct {
        var kinds: [8]effects_mod.EffectResultKind = undefined;
        var count: usize = 0;
        fn record(context: *anyopaque, record_value: effects_mod.EffectResultRecord) void {
            _ = context;
            kinds[count] = record_value.kind;
            count += 1;
        }
    };
    Capture.count = 0;
    var context: u8 = 0;
    fx.bindJournal(.{ .context = &context, .record_fn = Capture.record });

    Host.init(fx);
    Host.dispatch(fx, .stamp);
    // Synchronous: the stamped arm ran before dispatch returned, with
    // the clock read journaled for replay.
    try std.testing.expectEqual(@as(f64, 1_234), Host.model().stamp_ms);
    try std.testing.expectEqual(@as(usize, 1), Capture.count);
    try std.testing.expectEqual(effects_mod.EffectResultKind.clock, Capture.kinds[0]);
}

test "fire-and-forget records ride the host-call binding in wire order" {
    const fx = freshChannel();
    defer fx.deinit();
    fx.executor = .real;

    const Stub = struct {
        var names: [4][32]u8 = undefined;
        var payloads: [4][32]u8 = undefined;
        var lens: [4][2]usize = undefined;
        var count: usize = 0;
        fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
            _ = context;
            @memcpy(names[count][0..name.len], name);
            @memcpy(payloads[count][0..payload.len], payload);
            lens[count] = .{ name.len, payload.len };
            count += 1;
        }
        fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
            _ = context;
            _ = name;
            _ = key;
            _ = payload;
        }
    };
    Stub.count = 0;
    var context: u8 = 0;
    fx.bindHostCalls(.{ .context = &context, .send_fn = Stub.send, .request_fn = Stub.request });

    Host.init(fx);
    Host.dispatch(fx, .note);

    // persist -> core.persist, host -> the scalar arg block (f64 LE),
    // host_bytes -> the raw payload; wire record order preserved.
    try std.testing.expectEqual(@as(usize, 3), Stub.count);
    try std.testing.expectEqualStrings("core.persist", Stub.names[0][0..Stub.lens[0][0]]);
    try std.testing.expectEqual(@as(usize, 0), Stub.lens[0][1]);
    try std.testing.expectEqualStrings("gain.set", Stub.names[1][0..Stub.lens[1][0]]);
    var args: [16]u8 = undefined;
    std.mem.writeInt(u64, args[0..8], @bitCast(@as(f64, 0.5)), .little);
    std.mem.writeInt(u64, args[8..16], @bitCast(@as(f64, 2.0)), .little);
    try std.testing.expectEqualSlices(u8, &args, Stub.payloads[1][0..Stub.lens[1][1]]);
    try std.testing.expectEqualStrings("blob.put", Stub.names[2][0..Stub.lens[2][0]]);
    try std.testing.expectEqualStrings("hi", Stub.payloads[2][0..Stub.lens[2][1]]);
}

test "a request round-trips through a real host-call binding" {
    const fx = freshChannel();
    defer fx.deinit();
    fx.executor = .real;

    // The stub host service answers synchronously from request_fn —
    // the same feed path an async host completion uses later.
    const Stub = struct {
        var bound: ?*Fx = null;
        fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
            _ = context;
            _ = name;
            _ = payload;
        }
        fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
            _ = context;
            _ = payload;
            if (std.mem.eql(u8, name, "status.read")) {
                bound.?.feedHostResult(key, true, "live-answer") catch unreachable;
            } else {
                bound.?.feedHostResult(key, false, "no such service") catch unreachable;
            }
        }
    };
    Stub.bound = fx;
    var context: u8 = 0;
    fx.bindHostCalls(.{ .context = &context, .send_fn = Stub.send, .request_fn = Stub.request });

    Host.init(fx);
    Host.drain(fx);
    try std.testing.expectEqualStrings("live-answer", Host.model().status);
    try std.testing.expectEqual(@as(i64, 0), Host.model().errs);
}

test "a real-mode request without bound host services rejects loudly through the err arm" {
    const fx = freshChannel();
    defer fx.deinit();
    fx.executor = .real;

    Host.init(fx);
    Host.drain(fx);
    // The boot request could not run: exactly one err-route Msg.
    try std.testing.expectEqual(@as(i64, 1), Host.model().errs);
    try std.testing.expectEqualStrings("", Host.model().status);
}

// ------------------------------------------------- named engine ops

const load_effect_key: u64 = ts_core_host.effect_key_base + 0;

test "read_file issues the engine op and routes ok bytes / err reason arms" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .load_file);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    const request = fx.pendingFileAt(0).?;
    try std.testing.expectEqual(load_effect_key, request.key);
    try std.testing.expectEqual(effects_mod.EffectFileOp.read, request.op);
    try std.testing.expectEqualStrings("notes.bin", request.path);

    try fx.feedFileResult(load_effect_key, .ok, "disk bytes");
    Host.drain(fx);
    try std.testing.expectEqualStrings("disk bytes", Host.model().status);

    // The entry retired: the same slot re-issues, and a non-ok outcome
    // routes the err arm with the outcome's name as bytes.
    Host.dispatch(fx, .load_file);
    try fx.feedFileResult(load_effect_key, .not_found, "");
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 1), Host.model().errs);
    try std.testing.expectEqualStrings("not_found", Host.model().last_err);
    try std.testing.expectEqualStrings("disk bytes", Host.model().status);
}

test "write_file routes its payload-less ok arm and err reasons" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);
    Host.dispatch(fx, .{ .loaded = "content" });

    Host.dispatch(fx, .save_file);
    const request = fx.pendingFileAt(0).?;
    try std.testing.expectEqual(effects_mod.EffectFileOp.write, request.op);
    try std.testing.expectEqualStrings("notes.bin", request.path);
    try std.testing.expectEqualStrings("content", request.bytes);

    try fx.feedFileResult(load_effect_key, .ok, "");
    Host.drain(fx);
    try std.testing.expect(Host.model().saved);
    try std.testing.expectEqual(@as(i64, 0), Host.model().errs);

    Host.dispatch(fx, .save_file);
    try fx.feedFileResult(load_effect_key, .io_failed, "");
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 1), Host.model().errs);
    try std.testing.expectEqualStrings("io_failed", Host.model().last_err);
}

test "fetch decodes the wire record whole and routes the { status, body } ok arm by field type" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .get);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    const request = fx.pendingFetchAt(0).?;
    try std.testing.expectEqual(load_effect_key, request.key);
    try std.testing.expectEqual(std.http.Method.POST, request.method);
    try std.testing.expectEqualStrings("https://status.test/q", request.url);
    try std.testing.expectEqual(@as(usize, 1), request.headers.len);
    try std.testing.expectEqualStrings("accept", request.headers[0].name);
    try std.testing.expectEqualStrings("text/plain", request.headers[0].value);
    try std.testing.expectEqualStrings("ask", request.body);

    // A non-2xx status is still the ok route: an HTTP-level error is a
    // delivered response, exactly the engine's contract.
    try fx.feedResponse(load_effect_key, 404, "missing");
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 404), Host.model().code);
    try std.testing.expectEqualStrings("missing", Host.model().status);

    // Transport failures route the err arm with the outcome name.
    Host.dispatch(fx, .get);
    try fx.feedResponseOutcome(load_effect_key, .timed_out, 0, "");
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 1), Host.model().errs);
    try std.testing.expectEqualStrings("timed_out", Host.model().last_err);
    try std.testing.expectEqual(@as(i64, 404), Host.model().code);
}

test "fetch wire timeout 0 arms the engine default" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);
    Host.dispatch(fx, .get);
    // The fake table records what the engine armed; wire 0 must never
    // reach the engine as a zero timeout.
    const slot = fx.pendingFetchAt(0).?;
    _ = slot;
    // FetchRequest carries no timeout; the arm not rejecting (a zero
    // timeout is rejected by fetch validation) is the observable proof.
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
}

test "clip_write is fire-and-forget on a rotating key; clip_read routes ok and err arms" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .copy);
    Host.dispatch(fx, .copy);
    try std.testing.expectEqual(@as(usize, 2), fx.pendingClipboardCount());
    const first = fx.pendingClipboardAt(0).?;
    const second = fx.pendingClipboardAt(1).?;
    try std.testing.expectEqual(effects_mod.EffectClipboardOp.write, first.op);
    try std.testing.expectEqualStrings("hi", first.text);
    try std.testing.expectEqual(ts_core_host.clip_write_key_base + 0, first.key);
    try std.testing.expectEqual(ts_core_host.clip_write_key_base + 1, second.key);

    // No routing: terminals deliver to nobody, models untouched.
    try fx.feedClipboardResult(first.key, .ok, "");
    try fx.feedClipboardResult(second.key, .failed, "");
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 0), Host.model().errs);

    Host.dispatch(fx, .paste);
    const read = fx.pendingClipboardAt(0).?;
    try std.testing.expectEqual(effects_mod.EffectClipboardOp.read, read.op);
    try std.testing.expectEqual(load_effect_key, read.key);
    try fx.feedClipboardResult(load_effect_key, .ok, "pasted text");
    Host.drain(fx);
    try std.testing.expectEqualStrings("pasted text", Host.model().status);

    Host.dispatch(fx, .paste);
    try fx.feedClipboardResult(load_effect_key, .failed, "");
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 1), Host.model().errs);
    try std.testing.expectEqualStrings("failed", Host.model().last_err);
}

test "a delay arms one-shot, re-arms on re-issue, fires once, and cancels silently" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    const delay_key: u64 = ts_core_host.delay_key_base + 0;
    Host.dispatch(fx, .arm_delay);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingTimerCount());
    const timer = fx.pendingTimerAt(0).?;
    try std.testing.expectEqual(delay_key, timer.key);
    try std.testing.expectEqual(@as(u64, 250), timer.interval_ms);
    try std.testing.expectEqual(effects_mod.TimerMode.one_shot, timer.mode);

    // Re-issuing the live key re-arms the SAME slot (replace, not a
    // second timer) — the debounce discipline.
    Host.dispatch(fx, .arm_delay);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingTimerCount());
    try std.testing.expectEqual(delay_key, fx.pendingTimerAt(0).?.key);

    // The fire dispatches the named number arm once and retires the
    // slot: a second fire finds nothing.
    try fx.fireTimer(delay_key);
    Host.drain(fx);
    try std.testing.expectEqual(@as(f64, 0), Host.model().stamp_ms);
    try std.testing.expectError(error.EffectNotFound, fx.fireTimer(delay_key));

    // Cancel is silent: armed, cancelled, never fires, nothing routes.
    Host.dispatch(fx, .arm_delay);
    Host.dispatch(fx, .halt);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingTimerCount());
    try std.testing.expectError(error.EffectNotFound, fx.fireTimer(delay_key));
    try std.testing.expectEqual(@as(i64, 0), Host.model().errs);
}

test "reissuing a live named-op key replaces the op - the superseded result is dropped silently" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    // Two reads under one wire key in one command value: the second
    // REPLACES the first — the superseded op's engine call is cancelled
    // and only the new op stays live, under the next engine key.
    Host.dispatch(fx, .dup_load);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    // The superseded terminal routes NOTHING: no err arm, no message.
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 0), Host.model().errs);
    try std.testing.expectEqualStrings("", Host.model().last_err);

    // Only the second op's result dispatches.
    try fx.feedFileResult(ts_core_host.effect_key_base + 1, .ok, "second wins");
    Host.drain(fx);
    try std.testing.expectEqualStrings("second wins", Host.model().status);
}

test "issuing fetch under a live key replaces it - only the second response dispatches" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .get);
    Host.dispatch(fx, .get);
    // One live fetch: the replacement, on the next engine key.
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 0), Host.model().errs);

    try fx.feedResponse(ts_core_host.effect_key_base + 1, 200, "fresh");
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 200), Host.model().code);
    try std.testing.expectEqualStrings("fresh", Host.model().status);
}

test "cancelling a named engine op is silent - no arm dispatches and the key frees" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .load_file);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    Host.dispatch(fx, .drop_load);
    // The engine's `.cancelled` terminal retires the entry; the bridge
    // swallows it — nothing routes, matching request and delay.
    Host.drain(fx);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFileCount());
    try std.testing.expectEqual(@as(i64, 0), Host.model().errs);
    try std.testing.expectEqualStrings("", Host.model().last_err);

    // The dropped entry retired with its swallowed terminal: the key is
    // free again and a fresh op under it delivers normally.
    Host.dispatch(fx, .load_file);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    try fx.feedFileResult(load_effect_key, .ok, "after cancel");
    Host.drain(fx);
    try std.testing.expectEqualStrings("after cancel", Host.model().status);
}

test "cancel is silent for every named-op family - write_file, fetch, clip_read" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .save_file);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    Host.dispatch(fx, .drop_save);
    Host.drain(fx);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFileCount());
    try std.testing.expect(!Host.model().saved);

    Host.dispatch(fx, .get);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    Host.dispatch(fx, .drop_get);
    Host.drain(fx);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFetchCount());
    try std.testing.expectEqual(@as(i64, -1), Host.model().code);

    Host.dispatch(fx, .paste);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingClipboardCount());
    Host.dispatch(fx, .drop_paste);
    Host.drain(fx);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingClipboardCount());

    // Nothing routed anywhere: no ok arms, no err arms.
    try std.testing.expectEqual(@as(i64, 0), Host.model().errs);
    try std.testing.expectEqualStrings("", Host.model().last_err);
    try std.testing.expectEqualStrings("", Host.model().status);
}

// ------------------------------------------------------ spawn streams

const job_spawn_key: u64 = ts_core_host.spawn_key_base + 0;

test "a spawn stream decodes whole, routes lines repeatedly, and retires on the exit" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .run_lines);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    const request = fx.pendingSpawnAt(0).?;
    try std.testing.expectEqual(job_spawn_key, request.key);
    try std.testing.expectEqual(@as(usize, 2), request.argv.len);
    try std.testing.expectEqualStrings("/bin/probe", request.argv[0]);
    try std.testing.expectEqualStrings("--fast", request.argv[1]);
    try std.testing.expectEqualStrings("feed me", request.stdin);
    try std.testing.expectEqual(effects_mod.EffectOutputMode.lines, request.output);

    // The NON-RETIRING stream contract: lines route the line arm across
    // separate drains, and the entry stays live between them.
    try fx.feedLine(job_spawn_key, "cpu 12.5");
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 1), Host.model().line_count);
    try std.testing.expectEqualStrings("cpu 12.5", Host.model().last_line);
    try fx.feedLine(job_spawn_key, "cpu 40");
    try fx.feedLine(job_spawn_key, "cpu 7");
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 3), Host.model().line_count);
    try std.testing.expectEqualStrings("cpu 7", Host.model().last_line);

    // Exactly one terminal retires the entry: the exit code routes the
    // number arm, and the key is dead to further feeds.
    try fx.feedExit(job_spawn_key, 0);
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 0), Host.model().exit_code);
    try std.testing.expectError(error.EffectNotFound, fx.feedLine(job_spawn_key, "late"));
    try std.testing.expectEqual(@as(i64, 0), Host.model().errs);

    // The wire key is free again for a fresh stream in the same slot.
    Host.dispatch(fx, .run_lines);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    try std.testing.expectEqual(job_spawn_key, fx.pendingSpawnAt(0).?.key);
}

test "a line spawn without a line arm drops lines and still routes its exit" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .run_quiet);
    // No line routing (wire tag 0xFF): fed lines dispatch nothing.
    try fx.feedLine(job_spawn_key, "ignored");
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 0), Host.model().line_count);

    try fx.feedExit(job_spawn_key, 3);
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 3), Host.model().exit_code);
}

test "a collect spawn routes its exit as the { code, output } record by field type" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .run_collect);
    const request = fx.pendingSpawnAt(0).?;
    try std.testing.expectEqual(effects_mod.EffectOutputMode.collect, request.output);
    try std.testing.expectEqualStrings("/bin/ps", request.argv[0]);

    try fx.feedOutput(job_spawn_key, "PID CPU\n17 99.0\n");
    try fx.feedExit(job_spawn_key, 0);
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 0), Host.model().exit_code);
    try std.testing.expectEqualStrings("PID CPU\n17 99.0\n", Host.model().output);
    try std.testing.expectEqual(@as(i64, 0), Host.model().errs);

    // A non-zero code is still the exit route — the process RAN; its
    // failure code is the app's to read.
    Host.dispatch(fx, .run_collect);
    try fx.feedExit(job_spawn_key, 1);
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 1), Host.model().exit_code);
    try std.testing.expectEqual(@as(i64, 0), Host.model().errs);
}

test "a truncated collect routes err - a cut stdout never parses as whole" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .run_collect);
    // Overfill the collect buffer past the engine bound; the fake
    // executor mirrors the real truncation flag.
    const chunk = "x" ** 4096;
    var fed: usize = 0;
    while (fed <= effects_mod.max_effect_collect_bytes) : (fed += chunk.len) {
        try fx.feedOutput(job_spawn_key, chunk);
    }
    try fx.feedExit(job_spawn_key, 0);
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 1), Host.model().errs);
    try std.testing.expectEqualStrings("truncated", Host.model().last_err);
    try std.testing.expectEqualStrings("", Host.model().output);
}

test "cancelling a spawn mid-stream routes its err arm with cancelled and frees the key" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .run_lines);
    try fx.feedLine(job_spawn_key, "first");
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 1), Host.model().line_count);

    // Mid-stream cancel: the engine ends the child and delivers the
    // `.cancelled` exit — never silent — retiring the entry.
    Host.dispatch(fx, .stop_job);
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 1), Host.model().errs);
    try std.testing.expectEqualStrings("cancelled", Host.model().last_err);
    try std.testing.expectError(error.EffectNotFound, fx.feedLine(job_spawn_key, "late"));
    try std.testing.expectEqual(@as(i64, 1), Host.model().line_count);

    // The key is free for a fresh stream.
    Host.dispatch(fx, .run_lines);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
}

test "a duplicate spawn key rejects the new spawn through its err arm (the one exception)" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    // A running subprocess is never killed implicitly: unlike the named
    // ops, a live spawn key REJECTS the new spawn — cancel it first.
    Host.dispatch(fx, .dup_job);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    try std.testing.expectEqualStrings("/bin/one", fx.pendingSpawnAt(0).?.argv[0]);
    try std.testing.expectEqual(@as(i64, 1), Host.model().errs);
    try std.testing.expectEqualStrings("rejected", Host.model().last_err);

    // The surviving stream still delivers normally.
    try fx.feedExit(job_spawn_key, 0);
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 0), Host.model().exit_code);
}

test "non-exited spawn ends route the err arm with the reason name" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .run_lines);
    try fx.feedExitReason(job_spawn_key, -1, .spawn_failed);
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 1), Host.model().errs);
    try std.testing.expectEqualStrings("spawn_failed", Host.model().last_err);

    Host.dispatch(fx, .run_lines);
    try fx.feedExitReason(job_spawn_key, 9, .signaled);
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 2), Host.model().errs);
    try std.testing.expectEqualStrings("signaled", Host.model().last_err);
    // Neither end touched the exit-arm mirror.
    try std.testing.expectEqual(@as(i64, -1), Host.model().exit_code);
}

// ------------------------------------------------------- audio stream

test "audio_play decodes whole and events route the six-field arm by name" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .play);
    const request = fx.pendingAudio().?;
    try std.testing.expectEqual(ts_core_host.audio_key_base, request.key);
    try std.testing.expectEqualStrings("music/a.mp3", request.path);
    try std.testing.expectEqualStrings("", request.url);
    try std.testing.expectEqual(@as(u64, 0), request.expected_bytes);

    // The loaded acknowledgment routes the event arm; the state member
    // is matched by NAME (the mini core scrambles its declaration
    // order on purpose).
    try fx.feedAudioEvent(.loaded, 0, 183_000, true);
    Host.drain(fx);
    try std.testing.expectEqual(mini_core.AudioState.loaded, Host.model().audio_state);
    try std.testing.expectEqual(@as(f64, 183_000), Host.model().duration_ms);
    try std.testing.expect(Host.model().playing);
    try std.testing.expectEqual(@as(i64, 1), Host.model().audio_events);

    // Position ticks keep flowing through the same non-retiring entry.
    try fx.feedAudioEvent(.position, 1_500, 183_000, true);
    try fx.feedAudioEvent(.position, 2_000, 183_000, true);
    Host.drain(fx);
    try std.testing.expectEqual(mini_core.AudioState.position, Host.model().audio_state);
    try std.testing.expectEqual(@as(f64, 2_000), Host.model().position_ms);
    try std.testing.expectEqual(@as(i64, 3), Host.model().audio_events);

    // Spectrum bands arrive as bytes and commit into the model heap.
    var bands: [16]u8 = undefined;
    var full: [32]u8 = @splat(0);
    for (&bands, 0..) |*b, i| b.* = @intCast(i * 3);
    @memcpy(full[0..16], &bands);
    try fx.feedAudioSpectrum(full, 2_500, 183_000);
    Host.drain(fx);
    try std.testing.expectEqual(mini_core.AudioState.spectrum, Host.model().audio_state);
    try std.testing.expectEqual(@as(usize, 32), Host.model().bands.len);
    try std.testing.expectEqualSlices(u8, full[0..32], Host.model().bands);

    // completed does NOT close the stream (apps start the next track
    // from it); the entry keeps routing.
    try fx.feedAudioEvent(.completed, 183_000, 183_000, false);
    Host.drain(fx);
    try std.testing.expectEqual(mini_core.AudioState.completed, Host.model().audio_state);
    try std.testing.expect(!Host.model().playing);
    try std.testing.expectEqual(@as(i64, 5), Host.model().audio_events);
}

test "audio_ctl verbs drive the engine channel, gated by the wire key" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .play);
    try std.testing.expect(fx.audioSnapshot().playing);

    // A verb aimed at a key that is not the open stream is a no-op.
    Host.dispatch(fx, .ctl_stray);
    try std.testing.expect(fx.audioSnapshot().playing);

    Host.dispatch(fx, .pause_it);
    try std.testing.expect(!fx.audioSnapshot().playing);
    Host.dispatch(fx, .resume_it);
    try std.testing.expect(fx.audioSnapshot().playing);

    Host.dispatch(fx, .seek_it);
    try std.testing.expectEqual(@as(u64, 45_000), fx.audioSnapshot().position_ms);

    Host.dispatch(fx, .vol_it);
    try std.testing.expectEqual(@as(f32, 0.25), fx.pendingAudio().?.volume);

    // stop closes the stream: the channel idles, the entry retires,
    // and a straggler feed finds nothing.
    Host.dispatch(fx, .stop_it);
    try std.testing.expect(!fx.audioSnapshot().active);
    try std.testing.expectError(error.EffectNotFound, fx.feedAudioEvent(.position, 50_000, 183_000, true));
}

test "a replacing audio_play re-keys the stream and the url source decodes whole" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    Host.dispatch(fx, .play);
    // One player is the whole surface: the new play replaces in place.
    Host.dispatch(fx, .play_stream);
    const request = fx.pendingAudio().?;
    try std.testing.expectEqualStrings("", request.path);
    try std.testing.expectEqualStrings("https://cdn.test/a.mp3", request.url);
    try std.testing.expectEqualStrings("cache/a.mp3", request.cache_path);
    try std.testing.expectEqual(@as(u64, 4096), request.expected_bytes);

    // A failure event on the replaced stream routes honestly (never
    // silent) and does not close the entry.
    try fx.feedAudioEventBuffering(.failed, 0, 0, false, false);
    Host.drain(fx);
    try std.testing.expectEqual(mini_core.AudioState.failed, Host.model().audio_state);
    Host.dispatch(fx, .pause_it);
    try std.testing.expect(!fx.audioSnapshot().playing);
}

test "boot commits the model before any effects and performBoot fires the boot command once" {
    const fx = freshChannel();
    defer fx.deinit();

    // The pre-effects half: the committed boot model is readable, no
    // effect has been issued, and the frame arena is reset.
    Host.boot();
    try std.testing.expect(!Host.model().polling);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingHostCount());

    // The effects half re-derives the boot command from the pure
    // initialModel and performs it exactly as init does.
    Host.performBoot(fx);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingHostCount());
    const request = fx.pendingHostAt(0).?;
    try std.testing.expectEqual(boot_request_key, request.key);
    try std.testing.expectEqualStrings("status.read", request.name);
    try std.testing.expectEqualStrings("boot", request.payload);
}

test "a URL audio_play with no cache path derives the content-addressed path when configured" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    // No caches directory configured: the record plays stream-only,
    // exactly as its empty wire field says.
    Host.dispatch(fx, .play_bare_url);
    try std.testing.expectEqualStrings("", fx.pendingAudio().?.cache_path);

    // Configured: the bridge derives the engine's conventional path
    // from the URL alone — the same `audioCachePath` soundboard's
    // wiring computes.
    Host.setAudioCacheDir("/tmp/native-caches");
    Host.dispatch(fx, .play_bare_url);
    var expected_buffer: [512]u8 = undefined;
    const expected = try effects_mod.audioCachePath(&expected_buffer, "/tmp/native-caches", "https://cdn.test/b.mp3");
    try std.testing.expectEqualStrings(expected, fx.pendingAudio().?.cache_path);

    // A record that names its own cache path keeps it: derivation only
    // fills the empty field.
    Host.dispatch(fx, .play_stream);
    try std.testing.expectEqualStrings("cache/a.mp3", fx.pendingAudio().?.cache_path);
}

test "window verbs bridge to the effects channel's label-addressed verbs" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);
    const boot_pending = fx.pendingHostCount();

    // window_show decodes onto fx.showWindow: under the fake executor
    // the mirror records the request — count and label — exactly the
    // Zig tier's contract, so replay and hermetic tests see the same
    // observable.
    Host.dispatch(fx, .open_win);
    try std.testing.expectEqual(@as(u32, 1), fx.windowActionState().show_count);
    try std.testing.expectEqualStrings("player", fx.windowActionState().lastLabel());

    // quit_app decodes onto fx.quitApp — the graceful terminate request.
    Host.dispatch(fx, .quit_app);
    try std.testing.expectEqual(@as(u32, 1), fx.windowActionState().quit_count);

    // Fire-and-forget: neither verb parked a keyed effect or dispatched
    // a result Msg of its own — only init's boot request is pending.
    try std.testing.expectEqual(boot_pending, fx.pendingHostCount());
}

test "a channel opens, posts route the five-field arm by name, and close retires the key" {
    const fx = freshChannel();
    defer fx.deinit();
    Host.init(fx);

    // channel_open decodes onto fx.openChannel under the raw numeric
    // key; the native side resolves the thread-safe posting handle —
    // exactly what an embedder does.
    Host.dispatch(fx, .open_chan);
    const handle = fx.channelHandle(41) orelse return error.TestExpectedHandle;
    try std.testing.expectEqual(effects_mod.ChannelHandle.PostResult.accepted, handle.post("cpu 42%"));
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 1), Host.model().chan_events);
    try std.testing.expectEqual(mini_core.ChannelState.data, Host.model().chan_state);
    try std.testing.expectEqual(@as(f64, 41), Host.model().chan_key);
    try std.testing.expectEqualStrings("cpu 42%", Host.model().chan_bytes);
    try std.testing.expectEqual(@as(f64, 0), Host.model().chan_dropped_total);

    // A duplicate LIVE key rejects the new open at the post-cycle
    // boundary, echoing the refused key; the live channel is untouched.
    Host.dispatch(fx, .open_chan);
    try std.testing.expectEqual(@as(i64, 2), Host.model().chan_events);
    try std.testing.expectEqual(mini_core.ChannelState.rejected, Host.model().chan_state);
    try std.testing.expectEqual(@as(f64, 41), Host.model().chan_key);
    try std.testing.expect(fx.channelHandle(41) != null);

    // close: the staged post flushes ahead of the one closed terminal,
    // which retires the entry and kills the handle.
    try std.testing.expectEqual(effects_mod.ChannelHandle.PostResult.accepted, handle.post("last reading"));
    Host.dispatch(fx, .close_chan);
    Host.drain(fx);
    try std.testing.expectEqual(@as(i64, 4), Host.model().chan_events);
    try std.testing.expectEqual(mini_core.ChannelState.closed, Host.model().chan_state);
    try std.testing.expectEqual(effects_mod.ChannelHandle.PostResult.closed, handle.post("too late"));
    try std.testing.expect(fx.channelHandle(41) == null);

    // The key is free again: a fresh open lands with no rejection.
    Host.dispatch(fx, .open_chan);
    try std.testing.expectEqual(@as(i64, 4), Host.model().chan_events);
    try std.testing.expect(fx.channelHandle(41) != null);
}
