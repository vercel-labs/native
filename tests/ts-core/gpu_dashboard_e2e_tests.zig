const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("gpu_dashboard_core");
const decoder = @import("gpu_dashboard_decoder");
const reference = @import("gpu_dashboard_reference_access.zig");
const manifest = @import("gpu_dashboard_manifest");
const parity = @import("effects_media_parity.zig");
const testing = std.testing;
const canvas = sdk.canvas;
const Host = sdk.TsCoreHost(core);
const Adapter = sdk.TsUiApp(core);
const Ui = canvas.Ui(core.Msg);
const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));

test "GPU Dashboard shipping shell preserves the complete native scene" {
    try parity.equal(reference.migrationScene, comptime sdk.app_manifest.shellConfigFrom(manifest));
}

fn options() Adapter.Options {
    return Adapter.mobileOptions(.{}, .{ .name = "gpu-dashboard", .scene = reference.migrationScene, .canvas_label = "dashboard-canvas", .view = decoder.build });
}
fn compare(native: *const reference.Model, model: *const core.Model) !void {
    inline for (@typeInfo(reference.Model).@"struct".fields) |field| {
        const expected = @field(native, field.name);
        const actual = @field(model, field.name);
        if (comptime std.mem.eql(u8, field.name, "status_storage")) {
            try testing.expectEqualSlices(u8, &expected, actual);
        } else if (comptime @typeInfo(field.type) == .optional) {
            try testing.expectEqual(expected != null, actual != null);
            if (expected) |value| try testing.expectEqual(parity.number(value), parity.number(actual.?));
        } else if (comptime @typeInfo(field.type) == .@"enum") {
            try testing.expectEqualStrings(@tagName(expected), @tagName(actual));
        } else if (comptime @typeInfo(field.type) == .int or @typeInfo(field.type) == .float) {
            try testing.expectEqual(parity.number(expected), parity.number(actual));
        } else try testing.expectEqual(expected, actual);
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(native.status(), model.status(arena.allocator()));
}
fn apply(native: *reference.Model, fx: *Host.Fx, before: reference.Msg, after: core.Msg) !void {
    reference.update(native, before);
    Host.dispatch(fx, after);
    try compare(native, Host.model());
}
fn viewParity(native: *const reference.Model, model: *const core.Model) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var a = reference.DashboardUi.init(arena.allocator());
    const expected = try a.finalize(reference.view(&a, native));
    for (0..2) |backend| {
        var b = Ui.init(arena.allocator());
        const actual = try b.finalize(if (backend == 0) View.build(&b, model) else decoder.build(&b, model));
        core.rt.frameReset();
        try parity.equal(expected.root, actual.root);
        try testing.expectEqual(expected.handlers.len, actual.handlers.len);
        for (expected.handlers, actual.handlers) |old, new| {
            try testing.expectEqual(old.id, new.id);
            const left = expected.msgForPointer(old.id, .up);
            const right = actual.msgForPointer(new.id, .up);
            try testing.expectEqual(left != null, right != null);
            if (left) |message| try testing.expectEqualStrings(@tagName(message), @tagName(right.?));
        }
        var left: [128]canvas.WidgetLayoutNode = undefined;
        var right: [128]canvas.WidgetLayoutNode = undefined;
        for ([_]sdk.geometry.RectF{ .init(0, 0, 1240, 780), .init(0, 0, 1080, 640), .init(0, 0, 1600, 1000) }) |frame|
            try parity.equal(try canvas.layoutWidgetTree(expected.root, frame, &left), try canvas.layoutWidgetTree(actual.root, frame, &right));
    }
}

test "GPU Dashboard compiled model preserves all fields and status storage tails" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    Host.init(&fx);
    // The reference's initial buffer is unspecified; explicitly restore
    // every byte before comparing, including inactive trailing storage.
    var native: reference.Model = .{ .status_storage = @splat(0) };
    try compare(&native, Host.model());
    try viewParity(&native, Host.model());
    const tags = .{ "refresh", "set_mode", "toggle_live", "toggle_auto", "open_deployment", "submit_forecast", "submit_search", "perf_animation", "perf_animation_stop" };
    inline for (tags) |tag| {
        try apply(&native, &fx, @field(reference.Msg, tag), @field(core.Msg, tag));
        try viewParity(&native, Host.model());
    }
    for (0..3) |index| try apply(&native, &fx, .{ .select_nav = @intCast(index) }, .{ .select_nav = @intCast(index) });
    for (0..2) |index| try apply(&native, &fx, .{ .select_metric = @intCast(index) }, .{ .select_metric = @intCast(index) });
    for (0..4) |index| try apply(&native, &fx, .{ .select_activity = @intCast(index) }, .{ .select_activity = @intCast(index) });
    for (0..3) |index| try apply(&native, &fx, .{ .select_filter = @intCast(index) }, .{ .select_filter = @intCast(index) });
    try viewParity(&native, Host.model());
    for ([_]f32{ 0, 0.005, 0.015, 0.125, 0.495, 0.62, 0.995, 1 }) |value| {
        native.confidence = value; // native sync precedes its void message
        try apply(&native, &fx, .confidence_changed, .{ .confidence_changed = value });
    }
    inline for (.{ "light", "dark" }) |scheme| for ([_]bool{ false, true }) |contrast| for ([_]bool{ false, true }) |motion| {
        try apply(&native, &fx, .{ .set_appearance = .{ .color_scheme = @field(sdk.ColorScheme, scheme), .high_contrast = contrast, .reduce_motion = motion } }, .{ .set_appearance = .{ .colorScheme = @field(core.ColorScheme, scheme), .highContrast = contrast, .reduceMotion = motion } });
        try viewParity(&native, Host.model());
    };
    try testing.expectEqual(@as(usize, 0), fx.pendingTimerCount());
}

test "GPU Dashboard chrome and animation declarations match the independent native reference" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    Host.init(&fx);
    var native: reference.Model = .{ .status_storage = @splat(0) };
    const ts = options();
    const old = reference.migrationOptions();
    const state_app = try testing.allocator.create(Adapter.App);
    Adapter.App.initInPlace(state_app, testing.allocator, ts);
    state_app.model = Host.runtimeModel().*;
    defer state_app.destroy();
    inline for (.{ "light", "dark" }) |scheme| for ([_]bool{ false, true }) |contrast| for ([_]bool{ false, true }) |motion| {
        try apply(&native, &fx, .{ .set_appearance = .{ .color_scheme = @field(sdk.ColorScheme, scheme), .high_contrast = contrast, .reduce_motion = motion } }, .{ .set_appearance = .{ .colorScheme = @field(core.ColorScheme, scheme), .highContrast = contrast, .reduceMotion = motion } });
        const state = ts.theme_state_fn.?(Host.runtimeModel());
        try testing.expectEqual(contrast, state.high_contrast.?);
        try testing.expectEqual(motion, state.reduce_motion.?);
        const tokens = old.tokens_fn.?(&native);
        const observed = state_app.effectiveTokens();
        // Native and compiled portable policies have different function
        // addresses; compare every token value, not callback addresses.
        inline for (@typeInfo(canvas.DesignTokens).@"struct".fields) |field| {
            if (comptime !std.mem.endsWith(u8, field.name, "_policy") and !std.mem.eql(u8, field.name, "text_measure"))
                try parity.equal(@field(tokens, field.name), @field(observed, field.name));
        }
        for ([_]sdk.geometry.SizeF{ .init(1240, 780), .init(1080, 640), .init(0, 0), .init(1, 1), .init(17.5, 37.25), .init(1600, 1000) }) |size| {
            var a: [64]canvas.CanvasCommand = undefined;
            var b: [64]canvas.CanvasCommand = undefined;
            var left = canvas.Builder.init(&a);
            var right = canvas.Builder.init(&b);
            try old.chrome.?.build(&native, &left, size, tokens);
            try ts.chrome.?.build(Host.runtimeModel(), &right, size, tokens);
            core.rt.frameReset();
            try parity.equal(left.displayList(), right.displayList());
        }
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var a = reference.DashboardUi.init(arena.allocator());
        var b = Adapter.Ui.init(arena.allocator());
        const left = try a.finalize(reference.view(&a, &native));
        const right = try b.finalize(decoder.build(&b, Host.model()));
        for ([_]bool{ false, true }) |armed| {
            try apply(&native, &fx, if (armed) .perf_animation else .perf_animation_stop, if (armed) .perf_animation else .perf_animation_stop);
            var expected: [16]canvas.CanvasRenderAnimation = undefined;
            var actual: [16]canvas.CanvasRenderAnimation = undefined;
            const start: u64 = 18_446_744_073_709_551_000;
            const n = old.animations.?(&native, &left, start, &expected);
            const m = ts.animations.?(Host.runtimeModel(), &right, start, &actual);
            try testing.expectEqual(n, m);
            core.rt.frameReset();
            try parity.equal(expected[0..n], actual[0..m]);
            try testing.expectEqual(old.animations.?(&native, &left, start, expected[0..1]), ts.animations.?(Host.runtimeModel(), &right, start, actual[0..1]));
        }
    };
}

test "GPU Dashboard restoration owns complete storage and exact u32 boundary counters" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    inline for (.{ "refresh_count", "mode_count", "live_count" }, .{ "refresh", "set_mode", "toggle_live" }) |field, tag| {
        Host.init(&fx);
        const bytes = try testing.allocator.dupe(u8, core.persistenceSnapshot());
        defer testing.allocator.free(bytes);
        var native: reference.Model = .{ .status_storage = undefined };
        for (&native.status_storage, 0..) |*byte, index| byte.* = @truncate(index * 17 + 3);
        @field(native, field) = std.math.maxInt(u32) - 1;
        var at: usize = 4;
        for (0..std.mem.readInt(u32, bytes[0..4], .little)) |_| {
            const slot = std.mem.readInt(u32, bytes[at..][0..4], .little);
            const len = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
            at += 8;
            if (slot == 16) {
                try testing.expectEqual(@as(usize, 196), len);
                @memcpy(bytes[at + 4 ..][0..192], &native.status_storage);
            }
            const counter_slot: u32 = if (comptime std.mem.eql(u8, field, "refresh_count")) 0 else if (comptime std.mem.eql(u8, field, "mode_count")) 2 else 3;
            if (slot == counter_slot) std.mem.writeInt(i64, bytes[at..][0..8], std.math.maxInt(u32) - 1, .little);
            at += len;
        }
        Host.restoreSnapshot(bytes);
        @memset(bytes, 0xE7); // borrowed restore input cannot back the model
        core.rt.frameReset();
        try compare(&native, Host.model());
        try apply(&native, &fx, @field(reference.Msg, tag), @field(core.Msg, tag));
        core.rt.frameReset();
        try compare(&native, Host.model());
        try testing.expectEqual(@as(i64, std.math.maxInt(u32)), @field(Host.model(), field));
    }
}

fn dashboardReplay(comptime compiled_view: bool) !void {
    var buffer = parity.JournalBuffer.init();
    defer buffer.deinit();
    var recorder = sdk.runtime.SessionRecorder.init(.{ .context = &buffer, .write_fn = parity.JournalBuffer.write });
    recorder.begin(sdk.runtime.sessionHeaderNow(sdk.runtime.sessionPlatformName(), "gpu-dashboard", 1240, 780));
    var fingerprint: u64 = 0;
    var snapshot: ?[]u8 = null;
    var persistence: ?[]u8 = null;
    defer if (snapshot) |bytes| testing.allocator.free(bytes);
    defer if (persistence) |bytes| testing.allocator.free(bytes);
    const config: Adapter.Options = .{ .name = "gpu-dashboard", .scene = reference.migrationScene, .canvas_label = "dashboard-canvas", .view = if (compiled_view) decoder.build else View.build };
    {
        const state = try Adapter.create(testing.allocator, .{}, config);
        defer state.destroy();
        state.effects.executor = .fake;
        const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(1240, 780) });
        defer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = &recorder;
        try harness.start(state.app());
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{ .label = "dashboard-canvas", .size = .init(1240, 780), .frame_index = 1, .timestamp_ns = 9_007_199_254_740_993 } });
        for ([_][]const u8{ "Refresh dashboard", "Dashboard mode", "Live render status", "Overview", "ARR $12.8M, up 18.4%", "Last 30 days", "Queued invoices" }) |name|
            try parity.action(&harness.runtime, state.app(), &state.tree.?.root, "dashboard-canvas", name, "press");
        try parity.action(&harness.runtime, state.app(), &state.tree.?.root, "dashboard-canvas", "Auto refresh", "toggle");
        try parity.action(&harness.runtime, state.app(), &state.tree.?.root, "dashboard-canvas", "Confidence threshold", "increment");
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .appearance_changed = .{ .color_scheme = .dark, .reduce_motion = true, .high_contrast = true } });
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .menu_command = .{ .name = "dashboard.perf-animation", .window_id = 1 } });
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{ .label = "dashboard-canvas", .size = .init(1080, 640), .frame_index = 2, .timestamp_ns = 9_007_199_254_740_994, .canvas_command_count = 70, .canvas_frame_batch_count = 9, .canvas_frame_profile_work_units = std.math.maxInt(usize), .canvas_frame_profile_risk = .moderate, .canvas_frame_profile_dirty_ratio = 0.015, .canvas_frame_gpu_packet_representable = true } });
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .menu_command = .{ .name = "dashboard.perf-animation-stop", .window_id = 1 } });
        try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);
        fingerprint = harness.runtime.sessionStateFingerprint();
        snapshot = try testing.allocator.dupe(u8, core.modelSnapshot());
        persistence = try testing.allocator.dupe(u8, core.persistenceSnapshot());
        recorder.finish();
        try testing.expect(!recorder.failed);
        try testing.expectEqual(@as(usize, 0), state.effects.pendingTimerCount());
    }
    const state = try Adapter.create(testing.allocator, .{}, config);
    defer state.destroy();
    const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(1240, 780) });
    defer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const report = try sdk.runtime.replaySession(&harness.runtime, state.app(), buffer.bytes.written(), .{ .require_same_platform = false });
    try testing.expect(report.ok());
    try testing.expectEqual(recorder.event_count, report.events_replayed);
    try testing.expectEqual(recorder.checkpoint_count, report.checkpoints_verified);
    try testing.expectEqual(recorder.effect_count, report.effects_fed);
    try testing.expectEqual(fingerprint, harness.runtime.sessionStateFingerprint());
    try testing.expectEqualSlices(u8, snapshot.?, core.modelSnapshot());
    try testing.expectEqualSlices(u8, persistence.?, core.persistenceSnapshot());
    try testing.expectEqual(@as(usize, 0), state.effects.pendingTimerCount());
}

test "GPU Dashboard complete controls appearance diagnostics and retained animations replay on both views" {
    try dashboardReplay(false);
    try dashboardReplay(true);
}

test "GPU Dashboard copied frame diagnostics preserve exact unsigned counters" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    Host.init(&fx);
    const ts = options();
    const old = reference.migrationOptions();
    var native: reference.Model = .{ .status_storage = @splat(0) };
    const empty = sdk.platform.GpuFrame{ .label = "dashboard-canvas", .size = .init(1240, 780), .timestamp_ns = std.math.maxInt(u64), .frame_interval_ns = std.math.maxInt(u64) };
    try testing.expect(ts.on_frame.?(Host.runtimeModel(), empty) == null);
    const frame = sdk.platform.GpuFrame{ .label = "dashboard-canvas", .size = .init(1240, 780), .timestamp_ns = std.math.maxInt(u64), .frame_interval_ns = std.math.maxInt(u64), .canvas_command_count = std.math.maxInt(usize), .canvas_frame_batch_count = std.math.maxInt(usize), .canvas_frame_profile_work_units = std.math.maxInt(usize), .canvas_frame_profile_risk = .high, .canvas_frame_gpu_packet_representable = false, .canvas_frame_profile_dirty_ratio = 0.495 };
    const message = ts.on_frame.?(Host.runtimeModel(), frame).?;
    var expected: [20]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{d}", .{std.math.maxInt(usize)}), message.frame_status.commands);
    reference.update(&native, old.on_frame.?(&native, frame).?);
    Host.dispatch(&fx, message);
    core.rt.frameReset();
    try compare(&native, Host.model());
    try testing.expect(ts.on_frame.?(Host.runtimeModel(), frame) == null);
}
