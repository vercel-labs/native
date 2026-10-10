const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("deck_core");
const wire = @import("shim_rt.zig");
const ref = @import("deck_reference_access.zig");
const reference = ref.model;
const decoder = @import("deck_decoder");
const parity = @import("effects_media_parity.zig");
const Host = sdk.TsCoreHost(core);

fn equal(a: anytype, b: @TypeOf(a)) anyerror!void {
    switch (@typeInfo(@TypeOf(a))) {
        .@"struct" => |info| inline for (info.fields) |field| {
            equal(@field(a, field.name), @field(b, field.name)) catch |err| {
                std.debug.print("field {s}\n", .{field.name}); return err;
            };
        },
        .@"union" => {
            try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
            switch (a) { inline else => |value, tag| try equal(value, @field(b, @tagName(tag))) }
        },
        .pointer => |info| if (info.size == .slice) {
            try std.testing.expectEqual(a.len, b.len);
            for (a, b) |left, right| try equal(left, right);
        } else try equal(a.*, b.*),
        .array => for (a, b) |left, right| try equal(left, right),
        .optional => { try std.testing.expectEqual(a != null, b != null); if (a) |value| try equal(value, b.?); },
        .float => { const Bits = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(a))); try std.testing.expectEqual(@as(Bits, @bitCast(a)), @as(Bits, @bitCast(b))); },
        else => try std.testing.expectEqual(a, b),
    }
}
fn decimal(value: u64, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "{d}", .{value}) catch unreachable; }
fn playbackState(model: *const reference.Model, arena: std.mem.Allocator) core.PlaybackState {
    const frame = arena.alloc(u8, 8) catch unreachable;
    std.mem.writeInt(u64, frame[0..8], model.frame_ns, .little);
    const levels = arena.alloc(f64, 32) catch unreachable;
    const targets = arena.alloc(f64, 32) catch unreachable;
    for (levels, model.band_levels) |*out, in| out.* = in;
    for (targets, model.band_targets) |*out, in| out.* = in;
    return .{ .now = if (model.now) |id| id else null, .playing = model.playing, .elapsed_ms = @floatFromInt(model.elapsed_ms),
        .frame_ns = frame, .now_duration_ms = @floatFromInt(model.now_duration_ms), .platform_duration_ms = @floatFromInt(model.platform_duration_ms),
        .media_failed = model.media_failed, .stream_failed = model.stream_failed, .buffering = model.buffering,
        .seek_fraction = model.seek_fraction, .volume_fraction = model.volume_fraction, .url_base = model.urlBase(), .cache_dir = model.cacheDir(),
        .spectrum_live = model.spectrum_live, .band_targets = targets, .band_levels = levels };
}
fn restore(value: core.DeckState, arena: std.mem.Allocator) !*const core.Model {
    const bytes = wire.encodeAlloc(core.DeckState, value, arena);
    var out = std.Io.Writer.Allocating.init(arena);
    try out.writer.writeInt(u32, 1, .little);
    try out.writer.writeInt(u32, 0, .little);
    try out.writer.writeInt(u32, @intCast(bytes.len), .little);
    try out.writer.writeAll(bytes);
    Host.restoreSnapshot(out.written());
    return Host.model();
}
fn translated(msg: reference.Msg, arena: std.mem.Allocator) core.Msg {
    return switch (msg) {
        .play_track => |id| .{ .play_track = id },
        .frame_clock => |frame| .{ .frame_clock = .{ .timestamp_ns = decimal(frame.timestamp_ns, arena), .interval_ns = decimal(frame.interval_ns, arena) } },
        .audio_event => |event| .{ .audio_event = .{ .key = decimal(event.key, arena), .state = std.meta.stringToEnum(core.AudioState, @tagName(event.kind)).?,
            .positionMs = decimal(event.position_ms, arena), .durationMs = decimal(event.duration_ms, arena), .playing = event.playing, .buffering = event.buffering,
            .bands = arena.dupe(u8, &event.bands) catch unreachable } },
        .toggle_play => .toggle_play, .transport_play => .transport_play, .transport_pause => .transport_pause, .stop => .stop,
        .next_track => .next_track, .prev_track => .prev_track, .seeked => .seeked, .volume_changed => .volume_changed,
        .toggle_playlist => .toggle_playlist, .playlist_closed => .playlist_closed, .clear_search => .clear_search,
        .close_window => |window| .{ .close_window = std.meta.stringToEnum(core.WindowRef, @tagName(window)).? },
        .minimize_window => |window| .{ .minimize_window = std.meta.stringToEnum(core.WindowRef, @tagName(window)).? },
        .set_appearance => |value| .{ .set_appearance = .{ .colorScheme = std.meta.stringToEnum(core.ColorScheme, @tagName(value.color_scheme)).?, .reduceMotion = value.reduce_motion, .highContrast = value.high_contrast } },
        .search_edit => |edit| .{ .search_edit = translatedEdit(edit, arena) },
        .copy_title => |id| .{ .copy_title = id },
        .copied => |exit| .{ .copied = .{ .key = decimal(exit.key, arena), .code = exit.code,
            .reason = std.meta.stringToEnum(core.DeckExitReason, @tagName(exit.reason)).?, .droppedLines = @floatFromInt(exit.dropped_lines),
            .output = exit.output, .outputTruncated = exit.output_truncated, .stderrTail = exit.stderr_tail, .stderrTruncated = exit.stderr_truncated } },
    };
}

fn owned(comptime T: type, value: T, arena: std.mem.Allocator) *const T {
    const result = arena.create(T) catch unreachable; result.* = value; return result;
}
fn state(model: *const reference.Model, arena: std.mem.Allocator) core.DeckState {
    const covers = arena.alloc([]const u8, model.covers.len) catch unreachable;
    for (covers, model.covers) |*out, in| out.* = decimal(in, arena);
    return .{ .playlist_open = model.playlist_open,
        .appearance = owned(core.DeckAppearance, .{ .color_scheme = std.meta.stringToEnum(core.ColorScheme, @tagName(model.appearance.color_scheme)).?,
            .reduce_motion = model.appearance.reduce_motion, .high_contrast = model.appearance.high_contrast }, arena),
        .playback = owned(core.PlaybackState, playbackState(model, arena), arena),
        .url_base_buffer = model.url_base_buffer[0..], .url_base_len = @intCast(model.url_base_len),
        .cache_dir_buffer = model.cache_dir_buffer[0..], .cache_dir_len = @intCast(model.cache_dir_len),
        .search_buffer = owned(core.SearchBuffer, .{ .storage = model.search_buffer.storage[0..], .len = @intCast(model.search_buffer.len),
            .selection = .{ .anchor = @intCast(model.search_buffer.selection.anchor), .focus = @intCast(model.search_buffer.selection.focus) },
            .composition = if (model.search_buffer.composition) |range| .{ .start = @intCast(range.start), .end = @intCast(range.end) } else null,
            .truncated = model.search_buffer.truncated }, arena),
        .copies_done = model.copies_done, .copy_failed = model.copy_failed, .covers = covers };
}
fn translatedEdit(edit: sdk.canvas.TextInputEvent, arena: std.mem.Allocator) core.TextInputEvent {
    _ = arena;
    return switch (edit) {
        .insert_text => |bytes| .{ .insert_text = bytes },
        .set_composition => |value| .{ .set_composition = .{ .text = value.text, .cursor = if (value.cursor) |cursor| @intCast(cursor) else null } },
        .set_selection => |value| .{ .set_selection = .{ .anchor = @intCast(value.anchor), .focus = @intCast(value.focus) } },
        .move_caret => |value| .{ .move_caret = .{ .direction = std.meta.stringToEnum(core.TextCaretDirection, @tagName(value.direction)).?, .extend = value.extend } },
        inline else => |_, tag| @unionInit(core.TextInputEvent, @tagName(tag), {}),
    };
}
var transitions: usize = 0;
fn check(model: *const reference.Model, native: *reference.Effects, compiled: *Host.Fx, arena: std.mem.Allocator) !void {
    try equal(state(model, arena), Host.model().deck.*);
    try equal(native.audioSnapshot(), compiled.audioSnapshot());
    try equal(native.pendingAudio(), compiled.pendingAudio());
    try equal(native.windowActionState(), compiled.windowActionState());
    try std.testing.expectEqual(native.pendingSpawnCount(), compiled.pendingSpawnCount());
    for (0..native.pendingSpawnCount()) |index| {
        const a = native.pendingSpawnAt(index).?;
        const b = compiled.pendingSpawnAt(index).?;
        try std.testing.expectEqual(a.key, b.key);
        try equal(a.argv, b.argv);
        try equal(a.stdin, b.stdin);
        try std.testing.expectEqualStrings(@tagName(a.output), @tagName(b.output));
        try std.testing.expectEqual(a.max_line_bytes, b.max_line_bytes);
    }
    inline for (.{ "pendingTimerCount", "pendingHostCount", "pendingFileCount", "pendingFetchCount", "pendingImageLoadCount", "pendingClipboardCount", "pendingDbCount", "pendingPtyCount", "activeCount" }) |method| {
        try std.testing.expectEqual(@field(reference.Effects, method)(native), @field(Host.Fx, method)(compiled));
    }
}
fn drain(model: *reference.Model, native: *reference.Effects, compiled: *Host.Fx, arena: std.mem.Allocator) !void {
    var boundary = native.drainBoundary();
    while (native.takeMsgWithin(&boundary)) |message| reference.update(model, message, native);
    Host.drain(compiled);
    try check(model, native, compiled, arena);
}
fn step(model: *reference.Model, msg: reference.Msg) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const alloc = arena.allocator();
    var native = reference.Effects.init(std.testing.allocator); defer native.deinit(); native.executor = .fake;
    var compiled = Host.Fx.init(std.testing.allocator); defer compiled.deinit(); compiled.executor = .fake;
    Host.init(&compiled);
    const before = state(model, alloc);
    _ = try restore(before, alloc);
    try equal(before, Host.model().deck.*);
    reference.update(model, msg, &native);
    Host.dispatch(&compiled, translated(msg, alloc));
    try check(model, &native, &compiled, alloc);
    try drain(model, &native, &compiled, alloc);
    const snapshot = try alloc.dupe(u8, core.persistenceSnapshot());
    core.rt.frameReset();
    _ = core.snapshotModel().configureUrl("replacement", core.rt.frameAllocator());
    try std.testing.expectEqualSlices(u8, snapshot, core.persistenceSnapshot());
    try check(model, &native, &compiled, alloc);
    transitions += 1;
    core.rt.frameReset();
}

fn initial() reference.Model {
    var result: reference.Model = .{};
    result.search_buffer.storage = @splat(0);
    return result;
}
test "Deck complete native playback transitions and ordered commands across the catalog" {
    _ = core.initialModel();
    for (1..69) |id| for ([_]bool{ false, true }) |streaming| for ([_]u32{ 0, 1, 3000, 3001, 9000 }) |elapsed| {
        var model = initial();
        if (!streaming) model.setUrlBase("");
        model.setCacheDir("/audio-cache");
        try step(&model, .{ .play_track = @intCast(id) });
        model.elapsed_ms = elapsed;
        try step(&model, .transport_play);
        try step(&model, .transport_pause);
        try step(&model, .toggle_play);
        try step(&model, .prev_track);
        try step(&model, .next_track);
        try step(&model, .stop);
        for ([_]f32{ -1, 0, 0.1, 0.5, 1, 2 }) |fraction| {
            model.seek_fraction = fraction; model.volume_fraction = fraction;
            try step(&model, .seeked); try step(&model, .volume_changed);
        }
    };
    var idle = initial();
    for ([_]reference.Msg{ .stop, .next_track, .prev_track, .transport_pause, .seeked, .volume_changed, .toggle_play }) |msg| try step(&idle, msg);
    std.debug.print("complete catalog transport transitions: {d}\n", .{transitions});
}

test "Deck full audio reports preserve key filtering, duration, drift and spectrum ballistics" {
    _ = core.initialModel();
    for ([_]?u8{ null, 1, 68 }) |id| for ([_]u64{ 0, 1, 68, std.math.maxInt(u64) }) |key| {
        for (std.enums.values(sdk.EffectAudioEventKind)) |kind| for ([_]bool{ false, true }) |playing| for ([_]bool{ false, true }) |buffering| {
            for ([_]u64{ 0, 1, 9399, 9400, 9401, 9999, 10000, 10001, 10601, std.math.maxInt(u32), std.math.maxInt(u64) }) |position| {
                var model = initial();
                model.now = id; model.playing = playing; model.buffering = !buffering;
                model.elapsed_ms = 10000; model.now_duration_ms = if (playing) 20000 else 0;
                model.platform_duration_ms = 12; model.spectrum_live = playing;
                for (&model.band_levels, &model.band_targets, 0..) |*level, *target, index| { level.* = @as(f32, @floatFromInt(index)) / 31; target.* = 0.2; }
                var bands: [32]u8 = undefined; for (&bands, 0..) |*value, index| value.* = @intCast(index * 8);
                try step(&model, .{ .audio_event = .{ .key = key, .kind = kind, .position_ms = position, .duration_ms = position,
                    .playing = !playing, .buffering = buffering, .bands = bands } });
            }
        };
    };
    var model = initial();
    try step(&model, .{ .play_track = 1 });
    try step(&model, .{ .audio_event = .{ .key = 1, .kind = .spectrum, .bands = @splat(255) } });
    try step(&model, .{ .audio_event = .{ .key = 1, .kind = .spectrum, .bands = @splat(0) } });
    for ([_]u64{ 0, 1, 1000000, 16666666, 33333333, 66666666, 1000000000, 9007199254740993, std.math.maxInt(u64) }) |timestamp| {
        for ([_]u64{ 0, 1, 16666666, 33333333, 2000000000 }) |interval| {
            try step(&model, .{ .frame_clock = .{ .timestamp_ns = timestamp, .interval_ns = interval } });
        }
    }
    std.debug.print("complete playback transitions including audio/frame corpus: {d}\n", .{transitions});
}

test "Deck complete initial state, window policy and all appearance axes" {
    const current = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    var model = initial();
    try equal(state(&model, arena.allocator()), current.deck.*);
    for ([_]bool{ false, true }) |open| {
        model.playlist_open = open;
        for ([_]reference.Msg{ .toggle_playlist, .playlist_closed,
            .{ .close_window = .player }, .{ .close_window = .playlist },
            .{ .minimize_window = .player }, .{ .minimize_window = .playlist } }) |msg| try step(&model, msg);
    }
    for (std.enums.values(@FieldType(sdk.Appearance, "color_scheme"))) |scheme|
        for ([_]bool{ false, true }) |contrast| for ([_]bool{ false, true }) |motion|
            try step(&model, .{ .set_appearance = .{ .color_scheme = scheme, .high_contrast = contrast, .reduce_motion = motion } });
}

test "Deck search preserves every buffer byte, caret, composition and capacity refusal" {
    _ = core.initialModel();
    var model = initial();
    model.search_buffer.storage = @splat(0xa5);
    const inputs = [_][]const u8{ "", "alpha beta", "a\r\nb", "\xc3\xa9\xe9\x9f\xb3", "\x00\xff", "01234567890123456789012345678901234567890123456789", "012345678901234567890123456789012345678901234567890123456789" };
    for (inputs) |text| {
        try step(&model, .clear_search);
        try step(&model, .{ .search_edit = .{ .insert_text = text } });
        for ([_]usize{ 0, 1, 3, 24, 48, 99 }) |anchor| for ([_]usize{ 0, 2, 5, 48, 99 }) |focus| {
            try step(&model, .{ .search_edit = .{ .set_selection = .{ .anchor = anchor, .focus = focus } } });
            for (std.enums.values(sdk.canvas.TextCaretDirection)) |direction| for ([_]bool{ false, true }) |extend|
                try step(&model, .{ .search_edit = .{ .move_caret = .{ .direction = direction, .extend = extend } } });
        };
        for ([_]?usize{ null, 0, 1, 48 }) |cursor| {
            try step(&model, .{ .search_edit = .{ .set_composition = .{ .text = "\xc3\xa9 xy", .cursor = cursor } } });
            try step(&model, .{ .search_edit = .cancel_composition });
            try step(&model, .{ .search_edit = .{ .set_composition = .{ .text = text, .cursor = cursor } } });
            try step(&model, .{ .search_edit = .commit_composition });
        }
        for ([_]sdk.canvas.TextInputEvent{ .delete_backward, .delete_forward, .delete_word_backward, .delete_word_forward,
            .delete_to_start, .delete_to_line_start, .clear }) |edit| {
            try step(&model, .{ .search_edit = .{ .insert_text = text } });
            try step(&model, .{ .search_edit = edit });
        }
    }
    std.debug.print("complete state transitions after search corpus: {d}\n", .{transitions});
}

test "Deck launch configuration retains full buffers and refuses overlong values whole" {
    _ = core.initialModel();
    var input: [600]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @intCast(index % 256);
    for (0..601) |length| for ([_]bool{ false, true }) |slashes| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
        const alloc = arena.allocator();
        var model = initial();
        model.url_base_buffer = @splat(0xa5); model.url_base_len = 0;
        model.cache_dir_buffer = @splat(0x5a);
        const value = try alloc.dupe(u8, input[0..length]);
        if (slashes) for (value[length - @min(length, 5) ..]) |*byte| { byte.* = '/'; };
        var current = try restore(state(&model, alloc), alloc);
        try equal(state(&model, alloc), current.deck.*);
        const actual_url = current.configureUrl(value, alloc);
        model.setUrlBase(value);
        try equal(state(&model, alloc), actual_url.*);
        current = try restore(state(&model, alloc), alloc);
        try equal(state(&model, alloc), current.deck.*);
        const actual_cache = current.configureCache(value, alloc);
        model.setCacheDir(value);
        try equal(state(&model, alloc), actual_cache.*);
        core.rt.frameReset();
        _ = core.snapshotModel().configureUrl("replacement", core.rt.frameAllocator());
        // Previously returned state survives reset and another helper call.
        try equal(state(&model, alloc), actual_cache.*);
        core.rt.frameReset();
    };
    std.debug.print("complete launch configurations: 2404\n", .{});
}

test "Deck copy requests and all exit terminals preserve unrelated state and exact ids" {
    _ = core.initialModel();
    for (1..69) |id| {
        var model = initial();
        for (&model.covers, 0..) |*cover, index| cover.* = std.math.maxInt(u64) - index;
        try step(&model, .{ .copy_title = @intCast(id) });
    }
    for (std.enums.values(sdk.EffectExitReason)) |reason| for ([_]i32{ std.math.minInt(i32), -1, 0, 1, std.math.maxInt(i32) }) |code|
        for ([_]u64{ 0, 2, 9007199254740993, std.math.maxInt(u64) }) |key| for ([_]u32{ 0, 1, 4294967294 }) |copies| {
            var model = initial(); model.copies_done = copies; model.copy_failed = true;
            try step(&model, .{ .copied = .{ .key = key, .code = code, .reason = reason, .dropped_lines = std.math.maxInt(u32),
                .output = "\x00\xffpayload", .output_truncated = true, .stderr_tail = "\xff\x00error", .stderr_truncated = true } });
        };
    std.debug.print("complete state transitions including copy terminals: {d}\n", .{transitions});
}


test "Deck actual copy admission, duplicate refusal and terminal callback dispatch preserve ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const alloc = arena.allocator();
    var model = initial();
    var native = reference.Effects.init(std.testing.allocator); defer native.deinit(); native.executor = .fake;
    var compiled = Host.Fx.init(std.testing.allocator); defer compiled.deinit(); compiled.executor = .fake;
    Host.init(&compiled);
    _ = try restore(state(&model, alloc), alloc);
    for (std.enums.values(sdk.EffectExitReason)) |reason| for ([_]i32{ std.math.minInt(i32), -1, 0, 1, std.math.maxInt(i32) }) |code| {
        reference.update(&model, .{ .copy_title = 1 }, &native);
        Host.dispatch(&compiled, .{ .copy_title = 1 });
        try check(&model, &native, &compiled, alloc);
        reference.update(&model, .{ .copy_title = 68 }, &native);
        Host.dispatch(&compiled, .{ .copy_title = 68 });
        try check(&model, &native, &compiled, alloc);
        try drain(&model, &native, &compiled, alloc);
        try native.feedExitWithMetadata(2, code, reason, .{ .output_truncated = true, .stderr_truncated = true, .dropped_lines = std.math.maxInt(u32) });
        try compiled.feedExitWithMetadata(2, code, reason, .{ .output_truncated = true, .stderr_truncated = true, .dropped_lines = std.math.maxInt(u32) });
        try drain(&model, &native, &compiled, alloc);
        core.rt.frameReset();
        try check(&model, &native, &compiled, alloc);
    };
}

fn viewParity(native: *const reference.Model, model: *const core.Model, playlist: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const alloc = arena.allocator();
    var a = ref.view.Ui.init(alloc);
    const expected = try a.finalize(if (playlist) ref.view.playlistView(&a, native) else ref.view.rootView(&a, native));
    var b = sdk.canvas.Ui(core.Msg).init(alloc);
    const actual = try b.finalize(if (playlist) decoder.buildWindow(&b, model, "playlist") else decoder.build(&b, model));
    core.rt.frameReset();
    try parity.equal(expected.root, actual.root);
    try std.testing.expectEqual(expected.handlers.len, actual.handlers.len);
    for (expected.handlers, actual.handlers) |left, right| {
        try std.testing.expectEqual(left.id, right.id);
        const lm = expected.msgForPointer(left.id, .up); const rm = actual.msgForPointer(right.id, .up);
        try std.testing.expectEqual(lm != null, rm != null);
        if (lm) |msg| try equal(translated(msg, alloc), rm.?);
    }
    for (expected.handlers, actual.handlers) |left, right| {
        if (left.action == .context_menu) {
            try std.testing.expect(right.action == .context_menu);
            try std.testing.expectEqual(left.action.context_menu.len,right.action.context_menu.len);
            for (left.action.context_menu,right.action.context_menu) |before,after| {
                try std.testing.expectEqual(before != null,after != null);
                if (before) |msg| try equal(translated(msg,alloc),after.?);
            }
        }
    }
    var left: [1024]sdk.canvas.WidgetLayoutNode = undefined; var right: [1024]sdk.canvas.WidgetLayoutNode = undefined;
    const height: f32 = if (playlist) 440 else 264;
    for ([_]sdk.geometry.RectF{ .init(0, 0, 512, height), .init(0, 0, 600, height + 40), .init(0, 0, 480, height - 20) }) |frame| {
        try parity.equal(try sdk.canvas.layoutWidgetTree(expected.root, frame, &left), try sdk.canvas.layoutWidgetTree(actual.root, frame, &right));
    }
}

test "Deck production views preserve complete widgets layout actions and exact image identities" {
    ref.main.registerIcons();
    var fx = Host.Fx.init(std.testing.allocator); defer fx.deinit(); Host.init(&fx);
    var cases: usize = 0;
    for ([_]?u8{ null, 1, 8, 56 }) |now| for ([_]u64{0,1,9007199254740993,std.math.maxInt(u64)}) |cover| for ([_]u8{0,1,2,3,4,5}) |mode| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const alloc = arena.allocator();
        var native: reference.Model = .{}; native.now = now; native.covers = @splat(cover);
        native.playing = mode == 1 or mode == 5; native.buffering = mode == 2; native.media_failed = mode == 3; native.stream_failed = mode == 4;
        native.elapsed_ms = @as(u32, mode) * 51_123; native.now_duration_ms = 217_777;
        native.spectrum_live = mode == 5; for (&native.band_levels,0..) |*level,index| level.* = @as(f32,@floatFromInt(index%7))/8;
        if (mode == 3) native.search_buffer.set("missing") else if (mode == 5) native.search_buffer.set("A");
        native.search_buffer.storage[47] = 177; native.url_base_buffer[255] = 199;
        const model = try restore(state(&native,alloc),alloc); const saved = try alloc.dupe(u8,core.persistenceSnapshot());
        viewParity(&native,model,false) catch |err| { std.debug.print("main now={?d} cover={d} mode={d}\n",.{now,cover,mode});return err; };
        viewParity(&native,Host.model(),true) catch |err| { std.debug.print("playlist now={?d} cover={d} mode={d}\n",.{now,cover,mode});return err; };
        try std.testing.expectEqualSlices(u8,saved,core.persistenceSnapshot());
        try equal(state(&native,alloc),Host.model().deck.*);cases+=1;
    };
    std.debug.print("complete paired main/playlist states: {d}; layouts: {d}\n",.{cases*2,cases*6});
}

const stop = sdk.canvas.svg_icon.parseComptime(@embedFile("deck-reference/icons/stop.svg"));
const minimize = sdk.canvas.svg_icon.parseComptime(@embedFile("deck-reference/icons/minimize.svg"));
const originals = [_]sdk.canvas.icons.Entry{ .{ .name = "stop", .icon = &stop }, .{ .name = "minimize", .icon = &minimize } };
const cover_sources = [_][]const u8{
    @embedFile("deck-reference/art/exit-signs.jpg"), @embedFile("deck-reference/art/blue-season.jpg"),
    @embedFile("deck-reference/art/second-nature.jpg"), @embedFile("deck-reference/art/no-good-way-out.jpg"),
    @embedFile("deck-reference/art/glass-flowers.jpg"), @embedFile("deck-reference/art/night-bloom.jpg"),
    @embedFile("deck-reference/art/motion-picture.jpg"), @embedFile("deck-reference/art/channel-surfing.jpg"),
};
fn checkIcons() !void {
    const actual = sdk.canvas.icons.appIcons();
    try std.testing.expectEqual(originals.len, actual.len);
    for (originals, actual) |expected, observed| {
        try std.testing.expectEqualSlices(u8, expected.name, observed.name);
        try std.testing.expectEqualDeep(expected.icon.*, observed.icon.*);
    }
}
const Registry = struct {
    count: usize = 0,
    fn raw(_: *anyopaque, _: u64, _: usize, _: usize, _: []const u8) anyerror!void { return error.UnexpectedRawImage; }
    fn encoded(context: *anyopaque, id: u64, bytes: []const u8) anyerror!sdk.RegisteredImage {
        const self: *Registry = @ptrCast(@alignCast(context));
        try checkIcons();
        try std.testing.expectEqual(@as(u64, self.count + 1), id);
        try std.testing.expectEqualSlices(u8, cover_sources[self.count], bytes);
        self.count += 1;
        return .{ .width = 512, .height = 512 };
    }
    fn remove(_: *anyopaque, _: u64) bool { return false; }
    fn binding(self: *Registry) std.meta.Child(@FieldType(Host.Fx, "images")) {
        return .{ .context = self, .register_fn = raw, .register_bytes_fn = encoded, .unregister_fn = remove };
    }
};
fn qualify(comptime optimized: bool) !void {
    const Bridge = sdk.TsUiAppWithFeatures(core, .{ .runtime_markup = false, .compiled_model = optimized });
    const View = struct {
        fn build(ui: *Bridge.Ui, _: *const Bridge.Model) Bridge.Ui.Node {
            checkIcons() catch @panic("incomplete registered glyphs before first view");
            return ui.column(.{}, .{});
        }
        fn window(ui: *Bridge.Ui, model: *const Bridge.Model, _: []const u8) Bridge.Ui.Node {
            return build(ui, model);
        }
    };
    const images: [8]Bridge.BootImage = blk: {
        var result: [8]Bridge.BootImage = undefined;
        for (cover_sources, 0..) |bytes, ordinal| result[ordinal] = .{ .id = ordinal + 1, .bytes = bytes };
        break :blk result;
    };
    const compiled = try Bridge.create(std.testing.allocator, .{ .boot_images = &images }, .{
        .name = "deck-icons", .scene = .{ .windows = &.{} }, .canvas_label = "canvas", .view = View.build, .window_view = View.window,
    });
    defer compiled.destroy();
    compiled.effects.executor = .fake;
    var registry: Registry = .{};
    compiled.effects.bindImages(registry.binding());
    compiled.options.init_fx.?(&compiled.model, &compiled.effects);
    try std.testing.expectEqual(@as(usize, 8), registry.count);
    var ui = Bridge.Ui.init(std.testing.allocator);
    _ = View.build(&ui, &compiled.model);
    try checkIcons();
    const snapshot = try std.testing.allocator.dupe(u8, core.persistenceSnapshot());
    defer std.testing.allocator.free(snapshot);
    core.rt.frameReset();
    _ = core.snapshotModel().deckMarqueeText(core.rt.frameAllocator());
    core.rt.frameReset();
    try checkIcons();
    try std.testing.expectEqualSlices(u8, snapshot, core.persistenceSnapshot());
    const model = core.snapshotModel();
    for (model.deck.covers, 0..) |id, ordinal| {
        var bytes: [20]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&bytes, "{d}", .{ordinal + 1}), id);
    }
}
test "Deck vector glyphs match complete native SVG records before images and first view on both model representations" {
    const previous = sdk.canvas.icons.appIcons();
    defer sdk.canvas.icons.registerAppIcons(previous);
    try qualify(false);
    try qualify(true);
}

fn wholeOptions(comptime Bridge: type) Bridge.Options {
    return .{
        .name = "deck", .scene = comptime sdk.app_manifest.shellConfigFrom(@import("deck_manifest")),
        .canvas_label = "deck-canvas", .fonts = &ref.main.app_fonts,
        .on_command = core.commandMsg,
        .view = if (Bridge.Model == core.RuntimeModel) decoder.buildRuntime else decoder.build,
        .window_view = if (Bridge.Model == core.RuntimeModel) decoder.buildRuntimeWindow else decoder.buildWindow,
    };
}
fn wholeImages(comptime Bridge: type) [8]Bridge.BootImage {
    var result: [8]Bridge.BootImage = undefined;
    for (cover_sources, 0..) |bytes, ordinal| result[ordinal] = .{ .id = ordinal + 1, .bytes = bytes };
    return result;
}

// Text measurement is an explicitly owned native capability. Distinct
// runtimes hold distinct provider objects, even for the same font bytes.
fn displayEqual(expected: anytype, actual: @TypeOf(expected), left: *const sdk.Runtime, right: *const sdk.Runtime) anyerror!void {
    const T = @TypeOf(expected);
    if (comptime T == ?*const sdk.canvas.TextMeasureProvider) {
        try std.testing.expectEqual(expected != null, actual != null);
        if (expected) |a| {
            const b = actual.?;
            try std.testing.expectEqual(left.textMeasureProvider(), expected);
            try std.testing.expectEqual(right.textMeasureProvider(), actual);
            try std.testing.expectEqual(a.measure_fn, b.measure_fn);
            try std.testing.expectEqual(a.measure_advances_fn, b.measure_advances_fn);
            try std.testing.expectEqual(a.measure_ink_fn, b.measure_ink_fn);
        }
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "text_run_policy")) {
                // Native reference commands use the native planner. The
                // compiled app binds its canonical portable planner instead.
                try std.testing.expect(@field(expected, field.name) == null);
                const observed = @field(actual, field.name);
                try std.testing.expect(observed == null or observed == core.nativeWindowPolicy);
            } else displayEqual(@field(expected, field.name), @field(actual, field.name), left, right) catch |err| {
                std.debug.print("display field {s}\n", .{field.name}); return err;
            };
        },
        .optional => { try std.testing.expectEqual(expected != null, actual != null); if (expected) |value| try displayEqual(value, actual.?, left, right); },
        .pointer => |info| if (info.size == .slice) {
            try std.testing.expectEqual(expected.len, actual.len);
            for (expected, actual) |a, b| try displayEqual(a, b, left, right);
        } else try std.testing.expectEqual(expected, actual),
        .array => for (expected, actual) |a, b| try displayEqual(a, b, left, right),
        .@"union" => {
            try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
            switch (expected) { inline else => |value, tag| try displayEqual(value, @field(actual, @tagName(tag)), left, right) }
        },
        else => try equal(expected, actual),
    }
    if (comptime T == sdk.canvas.DrawText) {
        var a: [64]sdk.canvas.TextLine = undefined; var b: [64]sdk.canvas.TextLine = undefined;
        const options_a: sdk.canvas.TextLayoutOptions = expected.text_layout orelse .{ .measure = expected.measure, .text_run_policy = expected.text_run_policy };
        const options_b: sdk.canvas.TextLayoutOptions = actual.text_layout orelse .{ .measure = actual.measure, .text_run_policy = actual.text_run_policy };
        try equal(try sdk.canvas.layoutTextRun(expected, options_a, &a), try sdk.canvas.layoutTextRun(actual, options_b, &b));
    }
}

fn measurementEqual(left: *sdk.Runtime, right: *sdk.Runtime) !void {
    const fonts = left.registeredCanvasFonts();
    const other = right.registeredCanvasFonts();
    try std.testing.expectEqual(fonts.len, other.len);
    for (fonts, other) |a, b| {
        try std.testing.expectEqual(a.id, b.id);
        try equal(a.face.*, b.face.*);
        try std.testing.expectEqual(left.registeredCanvasFontFace(a.id), a.face);
        try std.testing.expectEqual(right.registeredCanvasFontFace(b.id), b.face);
    }
    const a = left.textMeasureProvider().?;
    const b = right.textMeasureProvider().?;
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(left)), a.context);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(right)), b.context);
    for (reference.tracks) |track| for ([_]f32{ 8, 12, 24, 36 }) |size| {
        try equal(a.measureWidth(64, size, track.title), b.measureWidth(64, size, track.title));
        var aa: [256]f32 = undefined; var bb: [256]f32 = undefined;
        const applied = a.measureAdvances(64, size, track.title, aa[0..track.title.len]);
        try std.testing.expectEqual(applied, b.measureAdvances(64, size, track.title, bb[0..track.title.len]));
        if (applied) try equal(@as([]const f32, aa[0..track.title.len]), @as([]const f32, bb[0..track.title.len]));
        try equal(a.measureInk(64, size, track.title), b.measureInk(64, size, track.title));
    };
}

fn snapshotWidget(runtime: *sdk.Runtime, label: []const u8, name: []const u8) !sdk.automation.snapshot.Widget {
    for (runtime.automationSnapshot("deck").widgets) |widget| {
        if (std.mem.eql(u8, widget.view_label, label) and std.mem.eql(u8, widget.name, name)) return widget;
    }
    return error.WidgetNotFound;
}

fn snapshotAction(runtime: *sdk.Runtime, app: sdk.App, label: []const u8, name: []const u8, verb: []const u8) !void {
    const widget = try snapshotWidget(runtime, label, name);
    var bytes: [512]u8 = undefined;
    try runtime.dispatchAutomationCommand(app, try std.fmt.bufPrint(&bytes, "widget-action {s} {d} {s}", .{ label, widget.id, verb }));
}

fn copyAction(runtime: *sdk.Runtime, app: sdk.App) !void {
    const widget = try snapshotWidget(runtime, "playlist-canvas", reference.tracks[0].title);
    var bytes: [128]u8 = undefined;
    try runtime.dispatchAutomationCommand(app, try std.fmt.bufPrint(&bytes, "widget-context-menu playlist-canvas {d} 0", .{widget.id}));
}

fn snapshotClick(runtime: *sdk.Runtime, app: sdk.App, label: []const u8, name: []const u8) !void {
    const widget = try snapshotWidget(runtime, label, name);
    var bytes: [256]u8 = undefined;
    try runtime.dispatchAutomationCommand(app, try std.fmt.bufPrint(&bytes, "widget-click {s} {d}", .{ label, widget.id }));
}

fn snapshotEqual(left: *sdk.Runtime, right: *sdk.Runtime, arena: std.mem.Allocator) !void {
    var a = left.automationSnapshot("deck");
    var b = right.automationSnapshot("deck");
    const av = try arena.dupe(sdk.platform.ViewInfo, a.views);
    const bv = try arena.dupe(sdk.platform.ViewInfo, b.views);
    // Automation samples each runtime's real monotonic input clock. Input
    // may be presented before the next controlled frame. Validate its real
    // duration and budget verdict, then compare all non-clock view fields.
    for ([_][]sdk.platform.ViewInfo{ av, bv }) |views| for (views) |*view| {
        if (view.gpu_input_timestamp_ns != 0) {
            const now = sdk.monotonicNanoseconds();
            try std.testing.expect(now >= view.gpu_input_timestamp_ns);
            try std.testing.expect(view.gpu_input_latency_ns <= now - view.gpu_input_timestamp_ns);
            const exceeded = view.gpu_input_latency_budget_ns > 0 and view.gpu_input_latency_ns > view.gpu_input_latency_budget_ns;
            try std.testing.expectEqual(@as(usize, @intFromBool(exceeded)), view.gpu_input_latency_budget_exceeded_count);
            try std.testing.expectEqual(!exceeded, view.gpu_input_latency_budget_ok);
        }
        view.gpu_input_timestamp_ns = 0;
        view.gpu_input_latency_ns = 0;
        view.gpu_input_latency_budget_exceeded_count = 0;
        view.gpu_input_latency_budget_ok = true;
    };
    a.views = av; b.views = bv;
    try parity.equal(a, b);
}

fn wholeAppReplay(comptime optimized: bool) !void {
    const Bridge = sdk.TsUiAppWithFeatures(core, .{ .runtime_markup = false, .compiled_model = optimized });
    const images = wholeImages(Bridge);
    const config = wholeOptions(Bridge);
    var journal = parity.JournalBuffer.init(); defer journal.deinit();
    var recorder = sdk.runtime.SessionRecorder.init(.{ .context = &journal, .write_fn = parity.JournalBuffer.write });
    recorder.begin(sdk.runtime.sessionHeaderNow(sdk.runtime.sessionPlatformName(), "deck", 512, 264));
    var fingerprint: u64 = 0;
    var saved: ?[]u8 = null; defer if (saved) |bytes| std.testing.allocator.free(bytes);
    var model_bytes: ?[]u8 = null; defer if (model_bytes) |bytes| std.testing.allocator.free(bytes);
    {
        const native = try ref.main.DeckApp.create(std.testing.allocator, ref.main.deckOptions());
        defer native.destroy(); native.model = initial(); native.effects.executor = .fake;
        // Both use the unchanged shipping manifest's placement policy.
        native.options.scene = config.scene;
        ref.main.registerIcons();
        const compiled = try Bridge.create(std.testing.allocator, .{ .boot_images = &images }, config);
        defer compiled.destroy(); compiled.effects.executor = .fake;
        const left = try sdk.TestHarness().create(std.testing.allocator, .{ .size = .init(512, 264) }); defer left.destroy(std.testing.allocator);
        const right = try sdk.TestHarness().create(std.testing.allocator, .{ .size = .init(512, 264) }); defer right.destroy(std.testing.allocator);
        left.null_platform.gpu_surfaces = true; right.null_platform.gpu_surfaces = true;
        right.runtime.options.session_recorder = &recorder;
        try left.start(native.app()); try right.start(compiled.app());
        left.runtime.started_timestamp_ns = 0; right.runtime.started_timestamp_ns = 0;
        left.runtime.views[0].gpu_surface_created_timestamp_ns = 1; right.runtime.views[0].gpu_surface_created_timestamp_ns = 1;
        for (0..32) |index| {
            for (left.runtime.views[0..left.runtime.view_count]) |*view| view.gpu_surface_created_timestamp_ns = 1;
            for (right.runtime.views[0..right.runtime.view_count]) |*view| view.gpu_surface_created_timestamp_ns = 1;
            const frame: sdk.platform.GpuSurfaceFrameEvent = .{ .label = "deck-canvas", .size = .init(512, 264), .frame_index = index + 1,
                .timestamp_ns = 9_007_199_254_740_993 + (index + 1) * 16_666_667, .frame_interval_ns = 16_666_667 };
            try left.runtime.dispatchPlatformEvent(native.app(), .{ .gpu_surface_frame = frame });
            try right.runtime.dispatchPlatformEvent(compiled.app(), .{ .gpu_surface_frame = frame });
            if (native.model.playlist_open) {
                try std.testing.expectEqual(@as(usize, 1), native.window_slot_count);
                if (compiled.window_slot_count != 1 or native.window_slots[0].window_id != compiled.window_slots[0].window_id) {
                    std.debug.print("Deck window slots at state {d}, optimized={any}: native={d}, compiled={d}, native id={d}, compiled id={d}\n", .{
                        index, optimized, native.window_slot_count, compiled.window_slot_count, native.window_slots[0].window_id,
                        if (compiled.window_slot_count > 0) compiled.window_slots[0].window_id else 0 });
                    return error.TestExpectedEqual;
                }
                const slot = &native.window_slots[0];
                var playlist_frame = frame;
                playlist_frame.window_id = slot.window_id;
                playlist_frame.label = "playlist-canvas";
                playlist_frame.size = .init(ref.view.playlist_width, ref.view.playlist_height);
                try left.runtime.dispatchPlatformEvent(native.app(), .{ .gpu_surface_frame = playlist_frame });
                try right.runtime.dispatchPlatformEvent(compiled.app(), .{ .gpu_surface_frame = playlist_frame });
                try displayEqual((try left.runtime.canvasDisplayList(slot.window_id, "playlist-canvas")).commands,
                    (try right.runtime.canvasDisplayList(slot.window_id, "playlist-canvas")).commands, &left.runtime, &right.runtime);
            }
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
            equal(state(&native.model, arena.allocator()), core.snapshotModel().deck.*) catch |err| {
                std.debug.print("whole Deck model at state {d}, optimized={any}\n", .{ index, optimized }); return err;
            };
            try parity.equal(native.effects.audioSnapshot(), compiled.effects.audioSnapshot());
            try parity.equal(native.effects.pendingAudio(), compiled.effects.pendingAudio());
            try parity.equal(native.effects.windowActionState(), compiled.effects.windowActionState());
            try std.testing.expectEqual(native.effects.pendingSpawnCount(), compiled.effects.pendingSpawnCount());
            for (0..native.effects.pendingSpawnCount()) |ordinal| try parity.equal(native.effects.pendingSpawnAt(ordinal).?, compiled.effects.pendingSpawnAt(ordinal).?);
            try parity.equal(left.runtime.registeredCanvasImages(), right.runtime.registeredCanvasImages());
            snapshotEqual(&left.runtime, &right.runtime, arena.allocator()) catch |err| {
                std.debug.print("whole Deck snapshot at state {d}, optimized={any}\n", .{ index, optimized }); return err;
            };
            try displayEqual((try left.runtime.canvasDisplayList(1, "deck-canvas")).commands, (try right.runtime.canvasDisplayList(1, "deck-canvas")).commands, &left.runtime, &right.runtime);
            if (index == 0) try measurementEqual(&left.runtime, &right.runtime);
            if (index == 31) break;
            if (index == 4) {
                try native.effects.feedAudioEventBuffering(.loaded, 0, 211_499, true, false);
                try compiled.effects.feedAudioEventBuffering(.loaded, 0, 211_499, true, false);
            } else if (index == 5) {
                var bands: [32]u8 = undefined; for (&bands, 0..) |*band, ordinal| band.* = @intCast(ordinal * 8);
                try native.effects.feedAudioSpectrum(bands, 1234, 211_499);
                try compiled.effects.feedAudioSpectrum(bands, 1234, 211_499);
            } else if (index == 6) {
                try native.effects.feedAudioEventBuffering(.position, 1234, 211_499, true, true);
                try compiled.effects.feedAudioEventBuffering(.position, 1234, 211_499, true, true);
            } else if (index == 10) {
                try native.effects.feedAudioEventBuffering(.failed, 0, 0, false, false);
                try compiled.effects.feedAudioEventBuffering(.failed, 0, 0, false, false);
            } else if (index == 11 or index == 12) {
                const appearance: sdk.Appearance = .{ .color_scheme = .dark, .reduce_motion = index == 12, .high_contrast = index == 11 };
                try left.runtime.dispatchPlatformEvent(native.app(), .{ .appearance_changed = appearance });
                try right.runtime.dispatchPlatformEvent(compiled.app(), .{ .appearance_changed = appearance });
            } else if (index >= 15) {
                switch (index) {
                    15, 27, 28, 29 => {
                        try left.runtime.dispatchAutomationCommand(native.app(), "menu-command deck.playlist");
                        try right.runtime.dispatchAutomationCommand(compiled.app(), "menu-command deck.playlist");
                    },
                    16, 23 => {
                        const verb = if (index == 16) "set_text does not match this catalog" else "set_text exit";
                        try snapshotAction(&left.runtime, native.app(), "playlist-canvas", "Search library", verb);
                        try snapshotAction(&right.runtime, compiled.app(), "playlist-canvas", "Search library", verb);
                    },
                    17, 24 => {
                        try left.runtime.dispatchAutomationCommand(native.app(), "menu-command deck.dismiss");
                        try right.runtime.dispatchAutomationCommand(compiled.app(), "menu-command deck.dismiss");
                    },
                    18 => {
                        try snapshotClick(&left.runtime, native.app(), "playlist-canvas", reference.tracks[0].title);
                        try snapshotClick(&right.runtime, compiled.app(), "playlist-canvas", reference.tracks[0].title);
                    },
                    19, 21 => {
                        try copyAction(&left.runtime, native.app());
                        try copyAction(&right.runtime, compiled.app());
                    },
                    20, 22 => {
                        const code: i32 = if (index == 20) 0 else 1;
                        try native.effects.feedExit(2, code);
                        try compiled.effects.feedExit(2, code);
                    },
                    25, 26 => {
                        const name = if (index == 25) "Minimize window" else "Close window";
                        try snapshotAction(&left.runtime, native.app(), "playlist-canvas", name, "press");
                        try snapshotAction(&right.runtime, compiled.app(), "playlist-canvas", name, "press");
                    },
                    30 => {
                        const id = native.window_slots[0].window_id;
                        try left.runtime.dispatchPlatformEvent(native.app(), left.null_platform.userCloseWindow(id).?);
                        try right.runtime.dispatchPlatformEvent(compiled.app(), right.null_platform.userCloseWindow(id).?);
                    },
                    else => unreachable,
                }
            } else {
                const name: []const u8 = switch (index) {
                    0 => "Play", 1 => "Pause", 2 => "Play", 3 => "Next track", 7 => "Pause", 8 => "Stop", 9 => "Play", 13 => "Play", 14 => "Stop", else => unreachable,
                };
                try parity.action(&left.runtime, native.app(), &native.tree.?.root, "deck-canvas", name, "press");
                try parity.action(&right.runtime, compiled.app(), &compiled.tree.?.root, "deck-canvas", name, "press");
            }
        }
        fingerprint = right.runtime.sessionStateFingerprint();
        saved = try std.testing.allocator.dupe(u8, core.persistenceSnapshot());
        model_bytes = try std.testing.allocator.dupe(u8, core.modelSnapshot());
        recorder.finish(); try std.testing.expect(!recorder.failed);
    }
    const replay = try Bridge.create(std.testing.allocator, .{ .boot_images = &images }, config); defer replay.destroy();
    const harness = try sdk.TestHarness().create(std.testing.allocator, .{ .size = .init(512, 264) }); defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const report = try sdk.runtime.replaySession(&harness.runtime, replay.app(), journal.bytes.written(), .{ .require_same_platform = false });
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(recorder.event_count, report.events_replayed);
    try std.testing.expectEqual(recorder.checkpoint_count, report.checkpoints_verified);
    try std.testing.expectEqual(recorder.effect_count, report.effects_fed);
    try std.testing.expectEqual(fingerprint, harness.runtime.sessionStateFingerprint());
    try std.testing.expectEqualSlices(u8, saved.?, core.persistenceSnapshot());
    try std.testing.expectEqualSlices(u8, model_bytes.?, core.modelSnapshot());
}

test "Deck whole shipping app preserves complete native snapshots chrome effects and sealed replay on both model representations" {
    try wholeAppReplay(false);
    try wholeAppReplay(true);
}

test "Deck complete theme and chrome commands retain all paths and gradients beyond frame reset" {
    var fx = Host.Fx.init(std.testing.allocator); defer fx.deinit(); Host.init(&fx);
    const Adapter = sdk.TsUiApp(core);
    const config = Adapter.mobileOptions(.{}, wholeOptions(Adapter));
    const app = try std.testing.allocator.create(Adapter.App);
    Adapter.App.initInPlace(app, std.testing.allocator, config); defer app.destroy();
    for ([_]bool{ false, true }) |contrast| for ([_]bool{ false, true }) |motion| for ([_]?u8{ null, 1 }) |now| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
        var native = initial(); native.appearance.high_contrast = contrast; native.appearance.reduce_motion = motion; native.now = now;
        native.volume_fraction = 0.125; native.elapsed_ms = 123_456;
        _ = try restore(state(&native, arena.allocator()), arena.allocator()); app.model = Host.runtimeModel().*;
        const tokens = ref.main.tokensFromModel(&native);
        const observed = app.effectiveTokens();
        inline for (@typeInfo(sdk.canvas.DesignTokens).@"struct".fields) |field| {
            if (comptime !std.mem.endsWith(u8, field.name, "_policy") and !std.mem.eql(u8, field.name, "text_measure"))
                try parity.equal(@field(tokens, field.name), @field(observed, field.name));
        }
        for ([_]sdk.geometry.SizeF{ .init(512, 264), .init(600, 440), .init(0, 0), .init(1, 1), .init(17.5, 37.25) }) |size| {
            var a: [256]sdk.canvas.CanvasCommand = undefined; var b: [256]sdk.canvas.CanvasCommand = undefined;
            var left = sdk.canvas.Builder.init(&a); var right = sdk.canvas.Builder.init(&b);
            try ref.main.deckOptions().chrome.?.build(&native, &left, size, tokens);
            try config.chrome.?.build(Host.runtimeModel(), &right, size, tokens);
            try config.chrome.?.build_suffix.?(Host.runtimeModel(), &right, size, tokens);
            core.rt.frameReset();
            const color: core.CanvasColor = .{ .r = 1, .g = 2, .b = 3, .a = 255 };
            _ = core.snapshotModel().canvasChromeSuffix(.{ .width = 512, .height = 264, .background = color, .surface = color, .border = color, .text = color }, core.rt.frameAllocator());
            core.rt.frameReset();
            try parity.equal(left.displayList(), right.displayList());
        }
    };
}
