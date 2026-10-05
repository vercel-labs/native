const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("video_player_core");
const decoder = @import("video_player_decoder");
const reference = @import("video_player_reference.zig");
const parity = @import("effects_media_parity.zig");
const canvas = sdk.canvas;
const Host = sdk.TsCoreHost(core);
const testing = std.testing;

fn compare(native: *const reference.Model, model: *const core.Model) !void {
    try testing.expectEqualStrings(@tagName(native.screen), @tagName(model.screen));
    try testing.expectEqualStrings(native.source_field.text(), model.source_field.text);
    try testing.expectEqual(native.source_field.truncated, model.source_truncated);
    try testing.expectEqual(@as(i64, @intCast(native.source_field.selection.anchor)), model.source_field.selection.anchor);
    try testing.expectEqual(@as(i64, @intCast(native.source_field.selection.focus)), model.source_field.selection.focus);
    try testing.expectEqual(native.source_field.composition != null, model.source_field.composition != null);
    if (native.source_field.composition) |range| {
        try testing.expectEqual(@as(i64, @intCast(range.start)), model.source_field.composition.?.start);
        try testing.expectEqual(@as(i64, @intCast(range.end)), model.source_field.composition.?.end);
    }
    try testing.expectEqualStrings(native.opened(), model.opened);
    try testing.expectEqual(native.status != null, model.status != null);
    if (native.status) |status| try testing.expectEqualStrings(@tagName(status), @tagName(model.status.?));
    inline for (.{ "playing", "buffering", "muted", "looping" }) |field| try testing.expectEqual(@field(native, field), @field(model, field));
    inline for (.{ "position_ms", "duration_ms", "width", "height" }) |field| try testing.expectEqual(@as(f64, @floatFromInt(@field(native, field))), parity.number(@field(model, field)));
    try testing.expectEqual(@as(f64, native.volume), model.volume);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(if (native.screen == .player) native.playerHint() else native.statusText(arena.allocator()), model.statusText(arena.allocator()));
}
fn viewParity(native: *const reference.Model, model: *const core.Model) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const State = canvas.Ui(reference.Msg).VideoPlaybackState;
    for ([_]State{
        .{},
        .{ .active = true, .playing = true, .buffering = true, .position_ms = 3723000, .duration_ms = 7325000, .surface = canvas.video_playback_surface_id, .width = 1920, .height = 1080 },
        .{ .active = true, .completed = true, .position_ms = 7325000, .duration_ms = 7325000, .surface = canvas.video_playback_surface_id, .width = 1920, .height = 1080 },
    }) |state| {
        var a = reference.PlayerUi.init(arena.allocator());
        a.video_state = state;
        const expected = try a.finalize(reference.view(&a, native));
        const Ui = canvas.Ui(core.Msg);
        const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));
        for (0..2) |backend| {
            var b = Ui.init(arena.allocator());
            b.video_state = .{ .active = state.active, .playing = state.playing, .buffering = state.buffering, .completed = state.completed, .position_ms = state.position_ms, .duration_ms = state.duration_ms, .surface = state.surface, .width = state.width, .height = state.height };
            const actual = try b.finalize(if (backend == 0) View.build(&b, model) else decoder.build(&b, model));
            core.rt.frameReset();
            try parity.equal(a.video_declaration, b.video_declaration);
            try parity.equal(expected.root, actual.root);
            try testing.expectEqual(expected.handlers.len, actual.handlers.len);
            for (expected.handlers, actual.handlers) |old, new| try testing.expectEqual(old.id, new.id);
            var left: [128]canvas.WidgetLayoutNode = undefined;
            var right: [128]canvas.WidgetLayoutNode = undefined;
            for ([_]sdk.geometry.RectF{ .init(0, 0, 760, 560), .init(0, 0, 980, 760), .init(0, 0, 560, 420) }) |frame| try parity.equal(try canvas.layoutWidgetTree(expected.root, frame, &left), try canvas.layoutWidgetTree(actual.root, frame, &right));
        }
    }
}
fn step(native: *reference.Model, native_fx: *reference.Effects, fx: *Host.Fx, old: reference.Msg, new: core.Msg) !void {
    reference.update(native, old, native_fx);
    Host.dispatch(fx, new);
    try compare(native, Host.model());
    try viewParity(native, Host.model());
}
test "compiled player preserves complete models, both view backends and native snapshot transport choices" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var native_fx = reference.Effects.init(testing.allocator);
    defer native_fx.deinit();
    native_fx.executor = .fake;
    var native = reference.Model{};
    Host.init(&fx);
    try compare(&native, Host.model());
    try viewParity(&native, Host.model());
    const source = "clips/orchard.mp4";
    native.setOpened(source);
    native.source_field.set(source);
    Host.dispatch(&fx, .{ .launch_source = source });
    try compare(&native, Host.model());
    try step(&native, &native_fx, &fx, .show_custom, .show_custom);
    try step(&native, &native_fx, &fx, .toggle_play, .toggle_play);
    // Commands echo no event: both actions must use the channel snapshot,
    // even though the event-fed model is now intentionally stale.
    try step(&native, &native_fx, &fx, .toggle_play, .toggle_play);
    try testing.expectEqual(native_fx.videoSnapshot().playing, fx.videoSnapshot().playing);
    try step(&native, &native_fx, &fx, .{ .video_event = .{ .key = 1, .kind = .loaded, .position_ms = 1234, .duration_ms = 3_723_000, .width = 1920, .height = 1080, .playing = true } }, .{ .video_event = .{ .state = .loaded, .positionMs = 1234, .durationMs = 3_723_000, .width = 1920, .height = 1080, .playing = true, .buffering = false } });
    for ([_]f32{ -1, 0, 0.12345678, 0.5, 1, 2 }) |value| {
        try step(&native, &native_fx, &fx, .{ .scrubbed = value }, .{ .scrubbed = value });
        try step(&native, &native_fx, &fx, .{ .set_volume = value }, .{ .set_volume = value });
        try testing.expectEqual(native_fx.videoSnapshot().position_ms, fx.videoSnapshot().position_ms);
        try testing.expectEqual(native_fx.videoSnapshot().volume, fx.videoSnapshot().volume);
    }
    try step(&native, &native_fx, &fx, .toggle_mute, .toggle_mute);
    try step(&native, &native_fx, &fx, .toggle_loop, .toggle_loop);
    try step(&native, &native_fx, &fx, .back, .back);
    try step(&native, &native_fx, &fx, .forward, .forward);
    try step(&native, &native_fx, &fx, .show_player, .show_player);
    try step(&native, &native_fx, &fx, .{ .source_edit = .{ .clear = {} } }, .{ .source_edit = .{ .clear = {} } });
    try step(&native, &native_fx, &fx, .open, .open);
    try step(&native, &native_fx, &fx, .show_custom, .show_custom);
}
test {
    _ = @import("video_player_reference_tests.zig");
}

fn playerReplay(comptime compiled_view: bool) !void {
    const Adapter = sdk.TsUiApp(core);
    const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));
    const env = [_]Adapter.EnvValue{.{ .msg = "launch_source", .value = "clips/orchard.mp4" }};
    var buffer = parity.JournalBuffer.init();
    defer buffer.deinit();
    const recorder = try testing.allocator.create(sdk.runtime.SessionRecorder);
    defer testing.allocator.destroy(recorder);
    recorder.* = .init(.{ .context = &buffer, .write_fn = parity.JournalBuffer.write });
    recorder.begin(sdk.runtime.sessionHeaderNow(sdk.runtime.sessionPlatformName(), "video-player", 760, 560));
    var fingerprint: u64 = 0;
    var full_model: ?[]u8 = null;
    defer if (full_model) |bytes| testing.allocator.free(bytes);
    {
        const state = try Adapter.create(testing.allocator, .{ .env_values = &env }, .{ .name = "video-player", .scene = reference.shell_scene, .canvas_label = reference.canvas_label, .view = if (compiled_view) decoder.build else View.build });
        const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(760, 560) });
        defer harness.destroy(testing.allocator);
        defer state.destroy();
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("clips/orchard.mp4", 60000, 1920, 1080);
        try harness.start(state.app());
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{ .label = reference.canvas_label, .size = .init(760, 560), .scale_factor = 1, .frame_index = 1, .timestamp_ns = 1_000_000 } });
        try harness.runtime.dispatchPlatformEvent(state.app(), harness.null_platform.takeVideoLoaded().?);
        try parity.action(&harness.runtime, state.app(), &state.tree.?.root, reference.canvas_label, "Custom", "toggle");
        try testing.expectEqual(core.Screen.custom, state.model.screen);
        try harness.runtime.dispatchPlatformEvent(state.app(), harness.null_platform.takeVideoLoaded().?);
        try harness.runtime.dispatchPlatformEvent(state.app(), harness.null_platform.advanceVideo(1234).?);
        try parity.action(&harness.runtime, state.app(), &state.tree.?.root, reference.canvas_label, "Pause", "press");
        try parity.action(&harness.runtime, state.app(), &state.tree.?.root, reference.canvas_label, "Play", "press");
        try parity.action(&harness.runtime, state.app(), &state.tree.?.root, reference.canvas_label, "Seek", "increment");
        try parity.action(&harness.runtime, state.app(), &state.tree.?.root, reference.canvas_label, "Volume", "decrement");
        try harness.runtime.dispatchPlatformEvent(state.app(), harness.null_platform.advanceVideo(60000).?);
        const token = state.effects.videoOwnerToken();
        try parity.action(&harness.runtime, state.app(), &state.tree.?.root, reference.canvas_label, "Play", "press");
        try testing.expect(state.effects.videoOwnerToken() != token);
        try harness.runtime.dispatchPlatformEvent(state.app(), harness.null_platform.takeVideoLoaded().?);
        try parity.action(&harness.runtime, state.app(), &state.tree.?.root, reference.canvas_label, "Pause", "press");
        try testing.expect(!state.effects.videoSnapshot().playing);
        try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);
        fingerprint = harness.runtime.sessionStateFingerprint();
        full_model = try std.json.Stringify.valueAlloc(testing.allocator, state.model, .{});
        recorder.finish();
        try testing.expect(!recorder.failed);
        try testing.expect(recorder.effect_count >= 4);
    }
    const state = try Adapter.create(testing.allocator, .{ .env_values = &env }, .{ .name = "video-player", .scene = reference.shell_scene, .canvas_label = reference.canvas_label, .view = if (compiled_view) decoder.build else View.build });
    const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(760, 560) });
    defer harness.destroy(testing.allocator);
    defer state.destroy();
    harness.null_platform.gpu_surfaces = true;
    const report = try sdk.runtime.replaySession(&harness.runtime, state.app(), buffer.bytes.written(), .{ .require_same_platform = false });
    try testing.expect(report.ok());
    try testing.expectEqual(recorder.event_count, report.events_replayed);
    try testing.expectEqual(recorder.checkpoint_count, report.checkpoints_verified);
    try testing.expectEqual(recorder.effect_count, report.effects_fed);
    try testing.expectEqual(fingerprint, harness.runtime.sessionStateFingerprint());
    const replayed = try std.json.Stringify.valueAlloc(testing.allocator, state.model, .{});
    defer testing.allocator.free(replayed);
    try testing.expectEqualStrings(full_model.?, replayed);
}
test "complete player model, transport ownership, effects and every checkpoint replay on both view backends" {
    try playerReplay(false);
    try playerReplay(true);
}
